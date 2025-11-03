"""Entry point for running the transcription worker as a module."""
from .worker import main

if __name__ == '__main__':
    raise SystemExit(main())
