# Whisper Transcriptie Analyse & Verbeteringen

## Huidige Situatie

### Configuratie (config.yml)
```yaml
transcription:
  whisper:
    model: tiny          # Klein model, snel maar minder accuraat
    language: nl         # Nederlands
    compute_type: int8   # Gekwantiseerd (8-bit integers)
    device: cpu          # CPU-gebaseerd
    beam_size: 3         # Laag (standaard is 5)
    temperature: 0.0     # Deterministisch
    vad_filter: false    # Voice Activity Detection uitgeschakeld
```

### Implementatie (worker.py)
De transcriptie gebeurt via `faster-whisper` library:
- Gebruikt `WhisperModel.transcribe()` methode
- Verwerkt audio segment per segment
- Extraheert timestamps, tekst en gedetecteerde taal
- Genereert keywords via frequentie-analyse

## Problemen met Huidige Setup

### 1. **Model: "tiny" is te klein**
- Het "tiny" model heeft slechts 39M parameters
- Laagste nauwkeurigheid van alle Whisper modellen
- Gemiddelde WER (Word Error Rate): ~15-20% voor Nederlands
- Mist veel nuances en maakt meer fouten

### 2. **Beam Size: 3 is te laag**
- Standaard is 5, je gebruikt 3
- Lagere beam size = sneller maar minder accurate transcripties
- Verkleint de zoekruimte voor mogelijke woorden

### 3. **VAD Filter uitgeschakeld**
- Voice Activity Detection zou kunnen helpen
- Comment zegt: "was filtering out too much audio"
- Maar zonder VAD wordt ook ruis getranscribeerd

## Aanbevolen Verbeteringen

### 🎯 Prioriteit 1: Upgrade naar groter model

#### Optie A: **small** model (Aanbevolen voor balans)
```yaml
whisper:
  model: small         # 244M parameters
  language: nl
  compute_type: int8
  device: cpu
  beam_size: 5         # Verhoog naar standaard
  temperature: 0.0
  vad_filter: false
```

**Voordelen:**
- ~5-8% betere WER dan tiny
- Nog steeds redelijk snel op CPU
- Goede balans tussen snelheid en nauwkeurigheid
- Config.default.yml gebruikt al 'small'

**Nadelen:**
- ~2-3x langzamer dan tiny
- Meer geheugen (ongeveer 1GB)

#### Optie B: **medium** model (Voor beste accuratie)
```yaml
whisper:
  model: medium        # 769M parameters
  language: nl
  compute_type: int8
  device: cpu
  beam_size: 5
  temperature: 0.0
  vad_filter: false
```

**Voordelen:**
- ~10-15% betere WER dan tiny
- Beste accuratie voor CPU-gebruik
- Goed voor complexe audio/meerdere sprekers

**Nadelen:**
- ~5-7x langzamer dan tiny
- Meer geheugen (~2.5GB)

#### Optie C: **large-v3** (Maximale kwaliteit, alleen als je tijd hebt)
```yaml
whisper:
  model: large-v3      # 1550M parameters
  language: nl
  compute_type: int8
  device: cpu
  beam_size: 5
  temperature: 0.0
  vad_filter: false
```

**Voordelen:**
- Beste beschikbare accuratie
- Laatste versie met verbeteringen

**Nadelen:**
- ~10x langzamer dan tiny
- Veel geheugen (~5GB)
- Mogelijk te traag voor achtergrondverwerking

### 🎯 Prioriteit 2: Verhoog beam_size

```yaml
beam_size: 5  # Of zelfs 7-10 voor beste resultaten
```

- Standaard is 5, je gebruikt 3
- Hogere beam size = betere transcripties maar langzamer
- Aanbeveling: Start met 5, probeer 7 als je tijd hebt

### 🎯 Prioriteit 3: Experimenteer met VAD

```yaml
vad_filter: true
vad_threshold: 0.5  # Experimenteer met 0.3 - 0.7
```

**Waarom het uitstaat:**
- Comment zegt: "it was filtering out too much audio"
- Maar moderne faster-whisper heeft betere VAD

**Oplossing:**
- Probeer opnieuw met lower threshold (0.3-0.4)
- Of upgrade faster-whisper versie (recente versies hebben betere VAD)

### 🎯 Prioriteit 4: Overweeg GPU-versnelling

Als je een NVIDIA GPU hebt:

```yaml
whisper:
  model: medium        # Groter model is nu haalbaar
  device: cuda         # Of 'cuda:0'
  compute_type: float16
  beam_size: 7
```

**Voordelen:**
- 10-20x sneller dan CPU
- Kan grotere modellen gebruiken
- Betere real-time mogelijkheden

**Check of je GPU hebt:**
```bash
nvidia-smi
# Of
lspci | grep -i nvidia
```

### 🎯 Prioriteit 5: Temperature tuning

```yaml
temperature: [0.0, 0.2, 0.4, 0.6, 0.8, 1.0]  # Fallback strategie
```

- Meerdere temperatures proberen als eerste poging faalt
- Helpt bij moeilijke audio
- Zie faster-whisper documentatie

### 🎯 Prioriteit 6: Overweeg initial_prompt

Voeg context toe voor betere herkenning:

```python
# In worker.py _run_transcription methode
initial_prompt = self._whisper_cfg.get('initial_prompt')
if initial_prompt:
    options['initial_prompt'] = initial_prompt
```

Voorbeeld in config:
```yaml
whisper:
  initial_prompt: "Dit is een vakantievideo opgenomen in Nederland."
```

## Snelle Test Setup

### Test 1: Minimale verbetering (Snel te implementeren)
```yaml
transcription:
  whisper:
    model: small         # Upgrade van tiny
    beam_size: 5         # Verhoog van 3
    # Rest blijft hetzelfde
```

**Verwachte verbetering:** 5-10% betere nauwkeurigheid, ~2x langzamer

### Test 2: Gebalanceerde verbetering
```yaml
transcription:
  whisper:
    model: small
    beam_size: 7
    vad_filter: true
    vad_threshold: 0.4
```

**Verwachte verbetering:** 10-15% betere nauwkeurigheid, ~3x langzamer

### Test 3: Maximale CPU verbetering
```yaml
transcription:
  whisper:
    model: medium
    beam_size: 7
    vad_filter: true
    vad_threshold: 0.4
    temperature: [0.0, 0.2, 0.4, 0.6, 0.8, 1.0]
```

**Verwachte verbetering:** 15-20% betere nauwkeurigheid, ~5x langzamer

## Implementatie Stappen

### Stap 1: Backup huidige config
```bash
cd /home/blackbox/Holiday-blackbox/Software
cp config.yml config.yml.backup
```

### Stap 2: Update config.yml
Kies een van de test setups hierboven en update je config.yml

### Stap 3: Test met één video
```bash
cd /home/blackbox/Holiday-blackbox/Software
python -m blackbox.transcription --once
```

### Stap 4: Vergelijk resultaten
Check de transcription.db voor voor/na vergelijking:
```bash
sqlite3 trips/My\ Trip/.blackbox/transcription.db "SELECT path, transcript FROM transcripts LIMIT 5;"
```

### Stap 5: Monitor prestaties
- Check CPU gebruik: `htop`
- Check geheugen: `free -h`
- Check transcriptie tijd in logs

## Model Vergelijkingstabel

| Model | Parameters | WER (NL) | Snelheid (CPU) | Geheugen | Aanbeveling |
|-------|-----------|----------|----------------|----------|-------------|
| tiny | 39M | ~18% | 1x (basis) | ~200MB | ❌ Te onnauwkeurig |
| base | 74M | ~15% | 1.5x | ~300MB | ⚠️ Marginale verbetering |
| small | 244M | ~10% | 2-3x | ~1GB | ✅ **Beste keuze** |
| medium | 769M | ~7% | 5-7x | ~2.5GB | ✅ Als tijd geen issue is |
| large-v3 | 1550M | ~5% | 10x | ~5GB | ⚠️ Overkill voor meeste use-cases |

## Code Verbeteringen (Optioneel)

### Voeg progress logging toe
In `worker.py`, rond regel 390:

```python
def _run_transcription(self, path: Path) -> Tuple[...]:
    model = self._load_transcriber()
    # ... existing code ...
    
    _LOG.info('Transcribing %s (model=%s, beam=%d)', 
              path, model_id, beam_size)
    
    start_time = time.time()
    segments_iter, info = model.transcribe(str(path), **options)
    
    # ... process segments ...
    
    elapsed = time.time() - start_time
    _LOG.info('Transcription completed in %.1fs (%d segments)', 
              elapsed, len(segments))
```

### Voeg error recovery toe
Probeer automatisch terug te vallen naar kleiner model bij fouten:

```python
def _run_transcription_with_fallback(self, path: Path):
    models_to_try = ['medium', 'small', 'base', 'tiny']
    current_model = self._whisper_cfg.get('model', 'small')
    
    # Start with configured model
    if current_model in models_to_try:
        models_to_try.remove(current_model)
        models_to_try.insert(0, current_model)
    
    for model_name in models_to_try:
        try:
            self._whisper_cfg['model'] = model_name
            self._transcriber = None  # Force reload
            return self._run_transcription(path)
        except Exception as e:
            _LOG.warning('Model %s failed: %s', model_name, e)
            continue
    
    raise RuntimeError('All model fallbacks failed')
```

## Monitoring & Debugging

### Check welk model momenteel actief is
```bash
cd /home/blackbox/Holiday-blackbox/Software
python -c "from blackbox.config import load_config; cfg = load_config(); print(cfg.get('transcription', {}).get('whisper', {}).get('model', 'unknown'))"
```

### Bekijk recente transcripties
```bash
cd trips/My\ Trip/.blackbox
sqlite3 transcription.db "SELECT path, length(transcript), transcript_model, updated_at FROM transcripts ORDER BY updated_at DESC LIMIT 10;"
```

### Clear oude transcripties om opnieuw te testen
```bash
python clear_transcripts.py  # Als dit script bestaat
# Of direct:
sqlite3 trips/My\ Trip/.blackbox/transcription.db "DELETE FROM transcripts WHERE transcript_model = 'tiny';"
```

## Conclusie & Aanbeveling

**Voor onmiddellijke verbetering:**
1. ✅ Update `config.yml`: model van `tiny` naar `small`
2. ✅ Verhoog `beam_size` van `3` naar `5`
3. ✅ Dit geeft ~5-10% betere nauwkeurigheid met acceptabele snelheid

**Voor optimale resultaten:**
1. Gebruik `medium` model als je tijd hebt (bijv. 's nachts transcriberen)
2. Verhoog `beam_size` naar `7`
3. Experimenteer met `vad_filter: true` met lagere threshold

**GPU check:**
Als je een NVIDIA GPU hebt, is dat een game-changer:
- Kan `large-v3` gebruiken met real-time snelheid
- Veel betere nauwkeurigheid zonder lange wachttijden

De huidige `config.default.yml` gebruikt al `small` model, dus dat is een goede start!
