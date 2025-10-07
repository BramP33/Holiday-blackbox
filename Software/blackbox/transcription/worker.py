from __future__ import annotations

import datetime as dt
import logging
import re
import time
from collections import Counter
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Tuple

try:
    import numpy as _np
except ImportError:  # pragma: no cover - optional dependency
    _np = None

from ..config import load_config
from ..paths import Paths
from .queue import TranscriptionQueue
from .semantic import SemanticModelUnavailable, available as semantic_available, encode_queries, encode_text

try:
    from faster_whisper import WhisperModel
except ImportError:  # pragma: no cover - optional dependency
    WhisperModel = None  # type: ignore

try:
    from sentence_transformers import SentenceTransformer
except ImportError:  # pragma: no cover - optional dependency
    SentenceTransformer = None  # type: ignore


_LOG = logging.getLogger(__name__)
if not _LOG.handlers:
    _handler = logging.StreamHandler()
    _handler.setFormatter(logging.Formatter('[Transcription] %(message)s'))
    _LOG.addHandler(_handler)
_LOG.setLevel(logging.INFO)


class MissingDependencyError(RuntimeError):
    pass


def _parse_time(value: Optional[str]) -> Optional[dt.time]:
    if not value:
        return None
    text = str(value).strip()
    if not text:
        return None
    parts = text.split(':')
    try:
        hour = int(parts[0])
        minute = int(parts[1]) if len(parts) > 1 else 0
    except (ValueError, IndexError):
        return None
    hour = max(0, min(hour, 23))
    minute = max(0, min(minute, 59))
    return dt.time(hour=hour, minute=minute)


_STOP_WORDS = {
    # English
    'a', 'an', 'and', 'are', 'as', 'at', 'be', 'but', 'by', 'for', 'if', 'in', 'into', 'is',
    'it', 'no', 'not', 'of', 'on', 'or', 'such', 'that', 'the', 'their', 'then', 'there', 'these',
    'they', 'this', 'to', 'was', 'will', 'with', 'we', 'you', 'your', 'from', 'have', 'has', 'had',
    'were', 'when', 'where', 'who', 'what', 'which', 'how', 'why', 'can', 'could', 'should', 'would',
    'do', 'does', 'did', 'so', 'than', 'very', 'more', 'less',
    # Dutch
    'de', 'het', 'een', 'en', 'van', 'ik', 'je', 'jij', 'wij', 'we', 'hij', 'zij', 'ze', 'hun', 'mijn',
    'jouw', 'ons', 'onze', 'zijn', 'haar', 'dit', 'dat', 'die', 'hier', 'daar', 'maar', 'als', 'dan',
    'voor', 'achter', 'bij', 'met', 'zonder', 'ook', 'niet', 'wel', 'om', 'te', 'naar', 'tot', 'uit',
    'over', 'onder', 'boven', 'weer', 'nog', 'al', 'alles', 'iets', 'niets', 'welke', 'hoe', 'waarom',
}

_WORD_RE = re.compile(r"[A-Za-zÀ-ÖØ-öø-ÿ0-9']+")


class TranscriptionWorker:
    """Background worker that processes queued videos after quiet hours."""

    def __init__(
        self,
        paths: Paths,
        queue: Optional[TranscriptionQueue] = None,
        cfg: Optional[dict] = None,
    ) -> None:
        self._paths = paths
        self._root = paths.trip_root()
        self._queue = queue or TranscriptionQueue(paths)
        self._cfg = cfg or load_config()
        self._transcriber: Optional[WhisperModel] = None
        self._kw_model: Optional[SentenceTransformer] = None
        self._kw_model_id: Optional[str] = None
        self._refresh_settings()

    # -- configuration ---------------------------------------------------
    def _refresh_settings(self) -> None:
        settings = dict(self._cfg.get('transcription') or {})
        self._enabled = bool(settings.get('enabled', True))
        whisper_cfg = dict(settings.get('whisper') or {})
        keywords_cfg = dict(settings.get('keywords') or {})
        semantic_cfg = dict(settings.get('semantic') or {})
        self._start_time = _parse_time(settings.get('start_time') or settings.get('window_start') or '22:00')
        end_value = settings.get('end_time') or settings.get('window_end')
        self._end_time = _parse_time(end_value) if end_value else None
        self._poll_seconds = float(settings.get('poll_seconds', 60.0))
        self._whisper_cfg = whisper_cfg
        self._keywords_cfg = keywords_cfg
        self._semantic_cfg = semantic_cfg
        self._semantic_enabled = bool(semantic_cfg.get('enabled', True))
        self._semantic_device = semantic_cfg.get('device', 'cpu')
        self._semantic_model_id = semantic_cfg.get('model') or 'sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2'
        if self._semantic_enabled and (not semantic_available() or _np is None):
            self._semantic_enabled = False

    # -- scheduling ------------------------------------------------------
    def _time_now(self) -> dt.datetime:
        return dt.datetime.now()

    def _in_window(self, now: Optional[dt.datetime] = None) -> bool:
        if not self._start_time:
            return True
        now = now or self._time_now()
        current = now.time()
        if self._end_time is None:
            return current >= self._start_time
        if self._start_time <= self._end_time:
            return self._start_time <= current < self._end_time
        return current >= self._start_time or current < self._end_time

    def _seconds_until_window(self, now: Optional[dt.datetime] = None) -> float:
        if not self._start_time:
            return 0.0
        now = now or self._time_now()
        if self._in_window(now):
            return 0.0
        today_start = now.replace(
            hour=self._start_time.hour,
            minute=self._start_time.minute,
            second=0,
            microsecond=0,
        )
        if self._end_time is None:
            if now.time() < self._start_time:
                return (today_start - now).total_seconds()
            tomorrow_start = today_start + dt.timedelta(days=1)
            return (tomorrow_start - now).total_seconds()
        if self._start_time <= self._end_time:
            if now.time() < self._start_time:
                return (today_start - now).total_seconds()
            tomorrow_start = today_start + dt.timedelta(days=1)
            return (tomorrow_start - now).total_seconds()
        if self._start_time > self._end_time:
            if now.time() >= self._end_time and now.time() < self._start_time:
                return (today_start - now).total_seconds()
            return 0.0
        return 0.0

    # -- models ----------------------------------------------------------
    def _model_root(self) -> Path:
        custom = self._whisper_cfg.get('model_dir')
        if custom:
            root = Path(custom).expanduser()
        else:
            root = self._paths.root / '.models'
        root.mkdir(parents=True, exist_ok=True)
        return root

    def _load_transcriber(self) -> WhisperModel:
        if WhisperModel is None:
            raise MissingDependencyError('faster-whisper is not installed')
        if self._transcriber is not None:
            return self._transcriber
        model_name = self._whisper_cfg.get('model') or 'tiny.en'
        model_path = self._whisper_cfg.get('model_path')
        compute_type = self._whisper_cfg.get('compute_type', 'int8')
        device = self._whisper_cfg.get('device', 'cpu')
        download_root = self._model_root()
        kwargs = {
            'device': device,
            'compute_type': compute_type,
            'download_root': str(download_root),
        }
        target = model_path or model_name
        _LOG.info('Loading Whisper model %s (device=%s compute=%s)', target, device, compute_type)
        self._transcriber = WhisperModel(target, **kwargs)
        return self._transcriber

    def _load_keyword_model(self) -> SentenceTransformer:
        if SentenceTransformer is None:
            raise MissingDependencyError('sentence-transformers is not installed')
        if self._kw_model is not None:
            return self._kw_model
        model_id = self._keywords_cfg.get('model') or 'sentence-transformers/all-MiniLM-L6-v2'
        device = self._keywords_cfg.get('device', 'cpu')
        _LOG.info('Loading sentence-transformer %s (device=%s)', model_id, device)
        self._kw_model = SentenceTransformer(model_id, device=device)
        self._kw_model_id = model_id
        return self._kw_model

    # -- keyword helpers -------------------------------------------------
    def _tokenize(self, text: str) -> List[str]:
        return _WORD_RE.findall(text.lower())

    def _candidate_phrases(self, tokens: List[str], max_len: int = 3) -> List[str]:
        phrases: List[str] = []
        window: List[str] = []
        for token in tokens:
            if token in _STOP_WORDS:
                if window:
                    phrases.extend(self._phrases_from_window(window, max_len))
                    window = []
                continue
            window.append(token)
        if window:
            phrases.extend(self._phrases_from_window(window, max_len))
        # Preserve order while removing duplicates
        seen = set()
        unique = []
        for phrase in phrases:
            if phrase not in seen:
                seen.add(phrase)
                unique.append(phrase)
        return unique

    def _phrases_from_window(self, window: List[str], max_len: int) -> List[str]:
        phrases: List[str] = []
        limit = min(len(window), max_len)
        for length in range(1, limit + 1):
            for idx in range(len(window) - length + 1):
                phrase = ' '.join(window[idx:idx + length])
                if len(phrase) >= 3:
                    phrases.append(phrase)
        return phrases

    def _keywords_frequency(self, text: str) -> Tuple[List[str], str]:
        tokens_all = self._tokenize(text)
        tokens = [tok for tok in tokens_all if tok not in _STOP_WORDS and len(tok) > 2]
        if not tokens:
            return [], 'frequency'
        phrases = tokens + self._candidate_phrases(tokens_all)
        counter = Counter(phrases)
        scored = counter.most_common()
        top_k = int(self._keywords_cfg.get('top_k', 12))
        keywords = [item for item, _ in scored[:top_k]]
        return keywords, 'frequency'

    def _keywords_sentence_transformer(self, text: str) -> Tuple[List[str], str]:
        model = self._load_keyword_model()
        tokens = [tok for tok in self._tokenize(text) if tok not in _STOP_WORDS]
        phrases = self._candidate_phrases(tokens)
        if not phrases:
            return [], self._kw_model_id or 'sentence-transformer'
        max_candidates = int(self._keywords_cfg.get('max_candidates', 256))
        phrases = phrases[:max_candidates]
        if _np is None:
            raise MissingDependencyError('numpy is required for sentence-transformer keyword extraction')
        doc_embedding = model.encode([text], normalize_embeddings=True)[0]
        cand_embeddings = model.encode(phrases, normalize_embeddings=True)
        scores = _np.dot(cand_embeddings, doc_embedding)
        order = _np.argsort(scores)[::-1]
        top_k = int(self._keywords_cfg.get('top_k', 12))
        keywords: List[str] = []
        seen = set()
        for idx in order:
            phrase = phrases[int(idx)]
            if phrase in seen:
                continue
            seen.add(phrase)
            keywords.append(phrase)
            if len(keywords) >= top_k:
                break
        return keywords, self._kw_model_id or 'sentence-transformer'

    def _extract_keywords(self, text: str) -> Tuple[List[str], str]:
        method = (self._keywords_cfg.get('method') or 'frequency').lower()
        if not text.strip():
            return [], method
        if method == 'sentence-transformer':
            return self._keywords_sentence_transformer(text)
        return self._keywords_frequency(text)

    def _backfill_semantic_embeddings(self) -> bool:
        if not self._semantic_enabled or not semantic_available() or _np is None:
            return False
        if not hasattr(self._queue, 'iter_missing_embeddings') or not hasattr(self._queue, 'store_embedding'):
            return False
        try:
            batch_size = max(1, int(self._semantic_cfg.get('backfill_batch', 16)))
        except (TypeError, ValueError):
            batch_size = 16
        try:
            pending: List[Tuple[str, str]] = []
            iterator = self._queue.iter_missing_embeddings(model=self._semantic_model_id)  # type: ignore[attr-defined]
            for rel_path, text in iterator:
                cleaned = (text or '').strip()
                if not cleaned:
                    continue
                pending.append((rel_path, cleaned))
                if len(pending) >= batch_size:
                    break
        except Exception:
            return False
        if not pending:
            return False
        try:
            vectors = encode_queries(
                [text for _, text in pending],
                model_id=self._semantic_model_id,
                device=self._semantic_device,
                normalize=True,
            )
        except (SemanticModelUnavailable, ValueError):
            return False
        except Exception:
            return False
        success = False
        for (rel_path, _), vec in zip(pending, vectors):
            try:
                arr = _np.asarray(vec, dtype=_np.float32)
            except Exception:
                continue
            if arr.size == 0:
                continue
            try:
                self._queue.store_embedding(rel_path, arr.tobytes(), self._semantic_model_id)  # type: ignore[attr-defined]
                success = True
            except Exception:
                continue
        return success

    # -- transcription ---------------------------------------------------
    def _run_transcription(self, path: Path) -> Tuple[str, List[Dict[str, float]], Optional[str], Optional[float], str]:
        model = self._load_transcriber()
        beam_size = int(self._whisper_cfg.get('beam_size', 5))
        temperature = float(self._whisper_cfg.get('temperature', 0.0))
        language_cfg = self._whisper_cfg.get('language')
        language: Optional[str]
        if language_cfg is None:
            language = None
        else:
            language_str = str(language_cfg).strip()
            lowered = language_str.lower()
            if not language_str or lowered in {'auto', 'detect', 'auto-detect', 'auto_detect'}:
                language = None
            else:
                language = language_str
        vad_filter = bool(self._whisper_cfg.get('vad_filter', False))
        task_cfg = self._whisper_cfg.get('task')
        task = str(task_cfg).strip().lower() if task_cfg else 'transcribe'
        if task not in {'transcribe', 'translate'}:
            task = 'transcribe'
        options = {
            'beam_size': beam_size,
            'temperature': temperature,
            'vad_filter': vad_filter,
            'task': task,
        }
        if language:
            options['language'] = language
        _LOG.info('Transcribing %s', path)
        segments_iter, info = model.transcribe(str(path), **options)
        segments: List[Dict[str, float]] = []
        parts: List[str] = []
        for seg in segments_iter:
            text = (seg.text or '').strip()
            if not text:
                continue
            segments.append({'start': float(seg.start), 'end': float(seg.end), 'text': text})
            parts.append(text)
        transcript = ' '.join(parts).strip()
        detected_language = getattr(info, 'language', None)
        duration = getattr(info, 'duration', None)
        model_id = self._whisper_cfg.get('model_path') or self._whisper_cfg.get('model') or 'unknown'
        return transcript, segments, detected_language, duration, str(model_id)

    # -- processing ------------------------------------------------------
    def process_next(self) -> bool:
        job = self._queue.next_pending()
        if not job:
            if self._backfill_semantic_embeddings():
                time.sleep(0.1)
                return True
            return False
        rel = job['path']
        path = self._root / rel
        if not path.exists():
            self._queue.mark_error(rel, 'file_missing')
            _LOG.warning('Skipping %s (file missing)', rel)
            return True
        self._queue.mark_processing(rel)
        try:
            transcript, segments, detected_language, duration, model_id = self._run_transcription(path)
            keywords, keyword_model = self._extract_keywords(transcript)
            embedding_bytes = None
            embedding_model_id = None
            if self._semantic_enabled:
                if not semantic_available():
                    raise MissingDependencyError('sentence-transformers is not installed for semantic search')
                if _np is None:
                    raise MissingDependencyError('numpy is required for semantic embeddings')
                try:
                    vector = encode_text(
                        transcript,
                        model_id=self._semantic_model_id,
                        device=self._semantic_device,
                        normalize=True,
                    )
                    arr = _np.asarray(vector, dtype=_np.float32)
                    embedding_bytes = arr.tobytes()
                    embedding_model_id = self._semantic_model_id
                except SemanticModelUnavailable as exc:
                    raise MissingDependencyError(str(exc)) from exc
            self._queue.mark_done(
                rel,
                transcript=transcript,
                segments=segments,
                keywords=keywords,
                transcript_model=model_id,
                keywords_model=keyword_model,
                language=detected_language,
                duration_sec=duration,
                embedding=embedding_bytes,
                embedding_model=embedding_model_id,
            )
            _LOG.info('Completed transcription for %s (%d segments)', rel, len(segments))
            self._backfill_semantic_embeddings()
        except MissingDependencyError as exc:
            message = f'missing_dependency: {exc}'
            self._queue.mark_error(rel, message)
            _LOG.error('Transcription blocked for %s: %s', rel, exc)
            time.sleep(max(self._poll_seconds, 60.0))
        except Exception as exc:  # pragma: no cover - runtime failures
            self._queue.mark_error(rel, f'error: {exc}')
            _LOG.exception('Transcription failed for %s', rel)
        return True

    def run_forever(self) -> None:
        _LOG.info('Transcription worker started')
        while True:
            if not self._enabled:
                time.sleep(self._poll_seconds)
                continue
            wait = self._seconds_until_window()
            if wait > 0:
                time.sleep(min(wait, max(self._poll_seconds, 30.0)))
                continue
            processed = self.process_next()
            if not processed:
                time.sleep(self._poll_seconds)

    def run_once(self, *, ignore_window: bool = False) -> None:
        if not self._enabled:
            _LOG.info('Transcription worker disabled in config')
            return
        if not ignore_window:
            wait = self._seconds_until_window()
            if wait > 0:
                _LOG.info('Outside transcription window, waiting %.0f seconds', wait)
                time.sleep(wait)
        while self.process_next():
            pass


def main(argv: Optional[Iterable[str]] = None) -> int:
    import argparse

    parser = argparse.ArgumentParser(description='Holiday Blackbox transcription worker')
    parser.add_argument('--once', action='store_true', help='Process pending items once and exit')
    args = parser.parse_args(list(argv) if argv is not None else None)

    cfg = load_config()
    paths = Paths(cfg).ensure()
    queue = TranscriptionQueue(paths)
    worker = TranscriptionWorker(paths, queue, cfg)
    if args.once:
        worker.run_once()
    else:
        worker.run_forever()
    return 0


if __name__ == '__main__':  # pragma: no cover
    raise SystemExit(main())
