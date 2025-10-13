#!/usr/bin/env python3
"""Clear all transcription data from the database."""

import sys
from pathlib import Path

# Add the parent directory to the path so we can import blackbox modules
sys.path.insert(0, str(Path(__file__).parent))

from blackbox.config import load_config
from blackbox.paths import Paths
from blackbox.transcription.queue import TranscriptionQueue

def main():
    # Load configuration and paths
    cfg = load_config()
    paths = Paths(cfg)
    
    # Create transcription queue instance
    queue = TranscriptionQueue(paths)
    
    # Get the database path
    db_path = queue._db_path
    print(f"Database path: {db_path}")
    
    if not db_path.exists():
        print("Database does not exist yet - no transcripts to delete.")
        return
    
    # Delete all transcripts
    try:
        conn = queue._conn_or_open()
        cursor = conn.cursor()
        cursor.execute("DELETE FROM transcripts")
        deleted = cursor.rowcount
        conn.commit()
        print(f"✓ Deleted {deleted} transcript(s) from database")
    except Exception as e:
        print(f"✗ Error deleting transcripts: {e}")
        sys.exit(1)

if __name__ == '__main__':
    main()
