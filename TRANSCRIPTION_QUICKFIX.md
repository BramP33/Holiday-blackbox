# Quick Fix voor Transcriptie Nauwkeurigheid

## TL;DR - Snelle Oplossing

Je gebruikt nu het **tiny** Whisper model met **beam_size 3** - dat is erg klein en onnauwkeurig.

### Aanbevolen wijziging in config.yml:

```yaml
transcription:
  enabled: true
  start_time: null
  end_time: null
  poll_seconds: 120
  whisper:
    model: small          # ✅ Was: tiny - geeft ~10% betere nauwkeurigheid
    language: nl
    compute_type: int8
    device: cpu
    beam_size: 5          # ✅ Was: 3 - hogere zoekbreedte = betere resultaten
    temperature: 0.0
    vad_filter: false
  keywords:
    method: frequency
    top_k: 8
  semantic:
    enabled: false
```

### Wat verbetert dit?

- **5-10% betere nauwkeurigheid** voor Nederlandse spraak
- **Minder fouten** in transcripties
- **Betere herkenning** van namen en plaatsnamen
- Ongeveer **2-3x langzamer** (maar nog steeds redelijk snel op CPU)

### Als je meer tijd hebt, probeer dan:

```yaml
whisper:
  model: medium         # 15-20% beter dan tiny
  beam_size: 7          # Nog betere resultaten
```

Dit is ~5x langzamer maar geeft significant betere resultaten.

## Test het:

```bash
cd /home/blackbox/Holiday-blackbox/Software

# Backup huidige config
cp config.yml config.yml.backup

# Edit config.yml (verander tiny -> small en 3 -> 5)
nano config.yml

# Test met één video
python -m blackbox.transcription --once
```

## Huidige vs Aanbevolen:

| Setting | Huidig | Aanbevolen | Verschil |
|---------|--------|------------|----------|
| Model | tiny (39M) | small (244M) | 6x groter |
| Beam Size | 3 | 5 | Standaard waarde |
| Snelheid | 1x | 2-3x langzamer | Acceptabel |
| Nauwkeurigheid | ~18% WER | ~10% WER | ~45% minder fouten |

De **config.default.yml** gebruikt al `small` model, dus dit is de intended configuratie!
