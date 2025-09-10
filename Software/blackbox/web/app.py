from __future__ import annotations
from flask import Flask, jsonify, send_file, render_template_string, request
from pathlib import Path
import os
from ..config import load_config, save_config
from ..paths import Paths


def create_app() -> Flask:
    cfg = load_config()
    paths = Paths(cfg).ensure()
    app = Flask(__name__)

    @app.get('/')
    def home():
        return render_template_string(
            """
            <html><head><title>Blackbox</title></head>
            <body>
            <h1>Blackbox</h1>
            <p><a href="/photos">Photos</a> | <a href="/videos">Videos</a> | <a href="/settings">Settings</a></p>
            </body></html>
            """
        )

    def _iter_media(root: Path, suffixes: set[str]):
        for dp, _, files in os.walk(root):
            for fn in files:
                p = Path(dp) / fn
                if p.suffix.lower() in suffixes:
                    yield p

    PHOTO_EXTS = {'.jpg', '.jpeg', '.png', '.rw2', '.cr2', '.nef', '.raf', '.dng', '.arw'}
    VIDEO_EXTS = {'.mp4', '.mov', '.m4v'}

    @app.get('/api/photos')
    def api_photos():
        root = paths.photos_dir()
        items = [str(p.relative_to(paths.trip_root())) for p in _iter_media(root, PHOTO_EXTS)]
        page = int(request.args.get('page', 1))
        size = int(load_config().get('web', {}).get('page_size', 50))
        start = (page - 1) * size
        end = start + size
        return jsonify({
            'page': page,
            'page_size': size,
            'total': len(items),
            'items': items[start:end],
        })

    @app.get('/api/videos')
    def api_videos():
        root = paths.trip_root()
        items = []
        for p in _iter_media(root, VIDEO_EXTS):
            items.append(str(p.relative_to(paths.trip_root())))
        page = int(request.args.get('page', 1))
        size = int(load_config().get('web', {}).get('page_size', 50))
        start = (page - 1) * size
        end = start + size
        return jsonify({
            'page': page,
            'page_size': size,
            'total': len(items),
            'items': items[start:end],
        })

    @app.get('/photos')
    def photos():
        root = paths.photos_dir()
        items = [str(p.relative_to(paths.trip_root())) for p in _iter_media(root, PHOTO_EXTS)]
        items.sort(key=lambda s: (paths.trip_root()/s).stat().st_mtime, reverse=True)
        page = int(request.args.get('page', 1))
        size = int(load_config().get('web', {}).get('page_size', 50))
        start = (page - 1) * size
        end = start + size
        page_items = items[start:end]
        html_items = '\n'.join(
            f'<a href="/download?p={i}"><img loading="lazy" style="max-width: 220px; margin:6px" src="/preview/photo?p={i}"></a>'
            for i in page_items
        )
        nav = f'<div><a href="/photos?page={max(1, page-1)}">Prev</a> | <a href="/photos?page={page+1}">Next</a></div>'
        return render_template_string(f"<h1>Photos</h1>{nav}<div>{html_items}</div>{nav}")

    @app.get('/videos')
    def videos():
        root = paths.trip_root()
        items = [str(p.relative_to(paths.trip_root())) for p in _iter_media(root, VIDEO_EXTS)]
        items.sort(key=lambda s: (paths.trip_root()/s).stat().st_mtime, reverse=True)
        page = int(request.args.get('page', 1))
        size = int(load_config().get('web', {}).get('page_size', 50))
        start = (page - 1) * size
        end = start + size
        page_items = items[start:end]
        html_items = '\n'.join(
            f'<div style="margin:8px 0"><video controls preload="metadata" width="320" src="/preview/video?p={i}"></video>\n'
            f'<div><a href="/download?p={i}">Download original</a></div></div>'
            for i in page_items
        )
        nav = f'<div><a href="/videos?page={max(1, page-1)}">Prev</a> | <a href="/videos?page={page+1}">Next</a></div>'
        return render_template_string(f"<h1>Videos</h1>{nav}<div>{html_items}</div>{nav}")

    @app.get('/preview/photo')
    def preview_photo():
        rel = request.args.get('p')
        if not rel:
            return 'missing p', 400
        from ..proxies.generate import thumb_name_for
        path = paths.trip_root() / rel
        thumb = thumb_name_for(path, paths.proxies_dir())
        if thumb.exists():
            return send_file(thumb)
        # fallback to original
        if path.exists():
            return send_file(path)
        return 'not found', 404

    @app.get('/preview/video')
    def preview_video():
        rel = request.args.get('p')
        if not rel:
            return 'missing p', 400
        from ..proxies.generate import proxy_name_for
        path = paths.trip_root() / rel
        proxy = proxy_name_for(path, paths.proxies_dir())
        if proxy.exists():
            return send_file(proxy)
        return 'not found', 404

    @app.get('/download')
    def download():
        rel = request.args.get('p')
        if not rel:
            return 'missing p', 400
        path = paths.trip_root() / rel
        if not path.exists():
            return 'not found', 404
        return send_file(path, as_attachment=True)

    def _render_settings_form(cfg: dict) -> str:
        return render_template_string(
            """
            <h1>Settings</h1>
            <form method="post">
              <fieldset><legend>Trip</legend>
                Name: <input name="trip.name" value="{{cfg['trip']['name']}}"><br>
                Begin: <input name="trip.begin_date" value="{{cfg['trip']['begin_date']}}"> (YYYY-MM-DD)<br>
                End: <input name="trip.end_date" value="{{cfg['trip']['end_date']}}"><br>
              </fieldset>
              <fieldset><legend>Verification</legend>
                Mode: <select name="verify.default_mode">
                  <option value="fast" {% if cfg['verify']['default_mode']=='fast' %}selected{% endif %}>Fast</option>
                  <option value="sha256" {% if cfg['verify']['default_mode']=='sha256' %}selected{% endif %}>SHA256</option>
                </select>
              </fieldset>
              <fieldset><legend>AP</legend>
                SSID: <input name="ap.ssid" value="{{cfg['ap']['ssid']}}"><br>
                Password: <input name="ap.password" value="{{cfg['ap']['password']}}"><br>
              </fieldset>
              <fieldset><legend>Web</legend>
                Page size: <input name="web.page_size" value="{{cfg['web']['page_size']}}" size="4">
              </fieldset>
              <fieldset><legend>Proxies</legend>
                Max cache GB: <input name="previews.max_cache_gb" value="{{cfg['previews']['max_cache_gb']}}" size="4">
              </fieldset>
              <button type="submit">Save</button>
            </form>
            """,
            cfg=cfg,
        )

    def _apply_flat_updates(cfg: dict, updates: dict) -> dict:
        for k, v in updates.items():
            path = k.split('.')
            cur = cfg
            for key in path[:-1]:
                cur = cur.setdefault(key, {})
            # try int cast for known numeric fields
            if path[-1] in {'page_size', 'max_cache_gb'}:
                try:
                    v = int(v)
                except Exception:
                    pass
            cur[path[-1]] = v
        return cfg

    @app.route('/settings', methods=['GET', 'POST'])
    def settings_page():
        cfg = load_config()
        if request.method == 'POST':
            if request.is_json:
                cfg.update(request.json or {})
            else:
                updates = {k: v for k, v in request.form.items()}
                cfg = _apply_flat_updates(cfg, updates)
            save_config(cfg)
        return _render_settings_form(cfg)

    return app


if __name__ == '__main__':
    cfg = load_config()
    app = create_app()
    app.run(host=cfg['web']['host'], port=int(cfg['web']['port']))
