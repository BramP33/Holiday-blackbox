#!/usr/bin/env python3
"""Test if Whisper small model can be loaded."""

from faster_whisper import WhisperModel

print('Loading small model...')
model = WhisperModel(
    'small',
    device='cpu',
    compute_type='int8',
    download_root='/home/blackbox/Holiday-blackbox/Software/.models'
)
print('Model loaded successfully!')
print('Model size: ~244M parameters')
print('Ready for transcription with better accuracy than tiny model')
