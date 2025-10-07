from __future__ import annotations

import json
import sqlite3
import threading
import time
import datetime as dt
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple, TYPE_CHECKING

if TYPE_CHECKING:
    from ..paths import Paths
else:
    Paths = object  # type: ignore


class TranscriptionQueue:
    """Persist transcription tasks and results for media files."""

    def __init__(self, paths: Paths, db_path: Optional[Path] = None) -> None:
        self._paths = paths
        self._root = paths.trip_root()
        meta_dir = self._root / '.meta'
        meta_dir.mkdir(parents=True, exist_ok=True)
        self._db_path = db_path or meta_dir / 'transcription.db'
        self._conn_lock = threading.Lock()
        self._conn: Optional[sqlite3.Connection] = None

    # -- database helpers -------------------------------------------------
    def _conn_or_open(self) -> sqlite3.Connection:
        with self._conn_lock:
            if self._conn is None:
                conn = sqlite3.connect(self._db_path, check_same_thread=False)
                conn.row_factory = sqlite3.Row
                conn.execute('PRAGMA journal_mode=WAL;')
                conn.execute('PRAGMA foreign_keys=ON;')
                self._migrate(conn)
                self._conn = conn
            return self._conn

    def _migrate(self, conn: sqlite3.Connection) -> None:
        conn.execute(
            '''
            CREATE TABLE IF NOT EXISTS transcripts (
                path TEXT PRIMARY KEY,
                state TEXT NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                started_at REAL,
                completed_at REAL,
                transcript TEXT,
                segments_json TEXT,
                keywords TEXT,
                transcript_model TEXT,
                keywords_model TEXT,
                language TEXT,
                duration_sec REAL,
                transcript_embedding BLOB,
                embedding_model TEXT,
                last_error TEXT,
                attempts INTEGER NOT NULL DEFAULT 0,
                file_mtime REAL
            )
            '''
        )
        conn.execute(
            'CREATE INDEX IF NOT EXISTS idx_transcripts_state ON transcripts(state, updated_at)'
        )
        conn.execute(
            'CREATE INDEX IF NOT EXISTS idx_transcripts_embedding ON transcripts(embedding_model)'
        )
        conn.commit()

    # -- helpers ----------------------------------------------------------
    def _relative_path(self, path: Path) -> Optional[str]:
        try:
            rel = path.resolve().relative_to(self._root.resolve())
        except ValueError:
            return None
        return rel.as_posix()

    def _row_to_dict(self, row: sqlite3.Row) -> Dict[str, Any]:
        data = dict(row)
        if data.get('segments_json'):
            try:
                data['segments'] = json.loads(data['segments_json'])
            except Exception:
                data['segments'] = []
        else:
            data['segments'] = []
        if data.get('keywords'):
            try:
                data['keywords_list'] = json.loads(data['keywords'])
            except Exception:
                data['keywords_list'] = []
        else:
            data['keywords_list'] = []
        return data

    # -- enqueue ----------------------------------------------------------
    def enqueue(self, path: Path, *, force: bool = False) -> bool:
        """Queue a video for transcription. Returns True if state changed."""
        rel = self._relative_path(path)
        if rel is None:
            return False
        try:
            stats = path.stat()
        except FileNotFoundError:
            return False
        mtime = stats.st_mtime
        now = time.time()
        conn = self._conn_or_open()
        row = conn.execute(
            'SELECT state, file_mtime FROM transcripts WHERE path = ?',
            (rel,),
        ).fetchone()
        if row is None:
            conn.execute(
                'INSERT INTO transcripts (path, state, created_at, updated_at, file_mtime) VALUES (?, ?, ?, ?, ?)',
                (rel, 'pending', now, now, mtime),
            )
            conn.commit()
            return True
        state = row['state'] or 'pending'
        existing_mtime = row['file_mtime']
        unchanged = (
            not force
            and state == 'pending'
            and existing_mtime is not None
            and abs(existing_mtime - mtime) < 0.5
        )
        if unchanged:
            return False
        conn.execute(
            '''
            UPDATE transcripts
               SET state = ?,
                   updated_at = ?,
                   started_at = NULL,
                   completed_at = NULL,
                   transcript = NULL,
                   segments_json = NULL,
                   keywords = NULL,
                   transcript_model = NULL,
                   keywords_model = NULL,
                   language = NULL,
                   duration_sec = NULL,
                   last_error = NULL,
                   attempts = 0,
                   file_mtime = ?
             WHERE path = ?
            ''',
            ('pending', now, mtime, rel),
        )
        conn.commit()
        return True

    # -- retrieval --------------------------------------------------------
    def get(self, rel_path: str) -> Optional[Dict[str, Any]]:
        conn = self._conn_or_open()
        row = conn.execute(
            'SELECT * FROM transcripts WHERE path = ?',
            (rel_path,),
        ).fetchone()
        if row is None:
            return None
        return self._row_to_dict(row)

    def get_many(self, rel_paths: Iterable[str]) -> Dict[str, Dict[str, Any]]:
        unique: list[str] = []
        seen: set[str] = set()
        for rel in rel_paths:
            if not rel:
                continue
            if rel not in seen:
                seen.add(rel)
                unique.append(rel)
        if not unique:
            return {}
        conn = self._conn_or_open()
        placeholders = ','.join('?' for _ in unique)
        try:
            rows = conn.execute(
                f'SELECT * FROM transcripts WHERE path IN ({placeholders})',
                unique,
            ).fetchall()
        except sqlite3.Error:
            return {}
        return {row['path']: self._row_to_dict(row) for row in rows}

    def next_pending(self) -> Optional[Dict[str, Any]]:
        conn = self._conn_or_open()
        row = conn.execute(
            'SELECT * FROM transcripts WHERE state = ? ORDER BY created_at ASC LIMIT 1',
            ('pending',),
        ).fetchone()
        if row is None:
            return None
        return self._row_to_dict(row)

    def pending_count(self) -> int:
        conn = self._conn_or_open()
        row = conn.execute(
            'SELECT COUNT(*) AS c FROM transcripts WHERE state = ?',
            ('pending',),
        ).fetchone()
        return int(row['c']) if row else 0

    def state_counts(self) -> Dict[str, int]:
        """Return counts grouped by job state."""
        conn = self._conn_or_open()
        rows = conn.execute(
            'SELECT state, COUNT(*) AS c FROM transcripts GROUP BY state'
        ).fetchall()
        summary: Dict[str, int] = {}
        for row in rows:
            state = (row['state'] or '').strip().lower() or 'unknown'
            summary[state] = int(row['c'] or 0)
        return summary

    def recent_errors(self, limit: int = 5) -> List[Dict[str, Any]]:
        """Return recent jobs that recorded an error message."""
        limit = max(1, int(limit))
        conn = self._conn_or_open()
        rows = conn.execute(
            '''
            SELECT path, state, last_error, updated_at, attempts
              FROM transcripts
             WHERE trim(coalesce(last_error, '')) != ''
             ORDER BY updated_at DESC
             LIMIT ?
            ''',
            (limit,),
        ).fetchall()
        items: List[Dict[str, Any]] = []
        for row in rows:
            ts = row['updated_at']
            if isinstance(ts, (int, float)):
                try:
                    updated = dt.datetime.fromtimestamp(ts, tz=dt.timezone.utc).isoformat()
                except Exception:
                    updated = None
            else:
                updated = None
            items.append(
                {
                    'path': row['path'],
                    'state': row['state'],
                    'last_error': row['last_error'],
                    'updated_at': updated,
                    'attempts': row['attempts'],
                }
            )
        return items

    # -- state transitions ------------------------------------------------
    def mark_processing(self, rel_path: str) -> None:
        now = time.time()
        conn = self._conn_or_open()
        conn.execute(
            '''
            UPDATE transcripts
               SET state = ?,
                   updated_at = ?,
                   started_at = coalesce(started_at, ?),
                   attempts = attempts + 1
             WHERE path = ?
            ''',
            ('processing', now, now, rel_path),
        )
        conn.commit()

    def mark_done(
        self,
        rel_path: str,
        *,
        transcript: str,
        segments: List[Dict[str, Any]],
        keywords: List[str],
        transcript_model: str,
        keywords_model: str,
        language: Optional[str],
        duration_sec: Optional[float],
        embedding: Optional[bytes] = None,
        embedding_model: Optional[str] = None,
    ) -> None:
        now = time.time()
        conn = self._conn_or_open()
        blob = sqlite3.Binary(embedding) if embedding is not None else None
        conn.execute(
            '''
            UPDATE transcripts
               SET state = ?,
                   updated_at = ?,
                   completed_at = ?,
                   transcript = ?,
                   segments_json = ?,
                   keywords = ?,
                   transcript_model = ?,
                   keywords_model = ?,
                   language = ?,
                   duration_sec = ?,
                   transcript_embedding = ?,
                   embedding_model = ?,
                   last_error = NULL
             WHERE path = ?
            ''',
            (
                'done',
                now,
                now,
                transcript,
                json.dumps(segments),
                json.dumps(keywords),
                transcript_model,
                keywords_model,
                language,
                duration_sec,
                blob,
                embedding_model,
                rel_path,
            ),
        )
        conn.commit()

    def mark_error(self, rel_path: str, message: str) -> None:
        now = time.time()
        conn = self._conn_or_open()
        conn.execute(
            '''
            UPDATE transcripts
               SET state = ?,
                   updated_at = ?,
                   last_error = ?,
                   completed_at = NULL
             WHERE path = ?
            ''',
            ('error', now, message, rel_path),
        )
        conn.commit()

    def reset_errors(self) -> int:
        now = time.time()
        conn = self._conn_or_open()
        cur = conn.execute(
            '''
            UPDATE transcripts
               SET state = 'pending',
                   updated_at = ?,
                   started_at = NULL,
                   completed_at = NULL,
                   last_error = NULL,
                   attempts = 0
             WHERE state = 'error'
            ''',
            (now,),
        )
        conn.commit()
        return cur.rowcount

    def all_jobs(self) -> list[Dict[str, Any]]:
        conn = self._conn_or_open()
        rows = conn.execute('SELECT * FROM transcripts ORDER BY created_at ASC').fetchall()
        return [self._row_to_dict(row) for row in rows]

    def get_embedding(self, rel_path: str) -> tuple[Optional[bytes], Optional[str]]:
        conn = self._conn_or_open()
        row = conn.execute(
            'SELECT transcript_embedding, embedding_model FROM transcripts WHERE path = ?',
            (rel_path,),
        ).fetchone()
        if row is None:
            return None, None
        return row['transcript_embedding'], row['embedding_model']

    def iter_embeddings(self, *, model: Optional[str] = None) -> Iterable[tuple[str, bytes, Optional[str]]]:
        conn = self._conn_or_open()
        if model:
            rows = conn.execute(
                'SELECT path, transcript_embedding, embedding_model FROM transcripts WHERE transcript_embedding IS NOT NULL AND embedding_model = ?',
                (model,),
            ).fetchall()
        else:
            rows = conn.execute(
                'SELECT path, transcript_embedding, embedding_model FROM transcripts WHERE transcript_embedding IS NOT NULL'
            ).fetchall()
        for row in rows:
            blob = row['transcript_embedding']
            if blob is None:
                continue
            yield row['path'], blob, row['embedding_model']

    def iter_missing_embeddings(self, *, model: str) -> Iterable[Tuple[str, str]]:
        conn = self._conn_or_open()
        rows = conn.execute(
            '''
            SELECT path, coalesce(transcript, '') AS transcript
              FROM transcripts
             WHERE state = 'done'
               AND trim(coalesce(transcript, '')) <> ''
               AND (
                    transcript_embedding IS NULL
                    OR embedding_model IS NULL
                    OR embedding_model <> ?
               )
            ''',
            (model,),
        ).fetchall()
        for row in rows:
            yield row['path'], row['transcript']

    def store_embedding(self, rel_path: str, embedding: bytes, model: str) -> None:
        now = time.time()
        conn = self._conn_or_open()
        conn.execute(
            '''
            UPDATE transcripts
               SET transcript_embedding = ?,
                   embedding_model = ?,
                   updated_at = ?
             WHERE path = ?
            ''',
            (
                sqlite3.Binary(embedding),
                model,
                now,
                rel_path,
            ),
        )
        conn.commit()
