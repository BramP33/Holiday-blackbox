from __future__ import annotations

import json
import math
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Tuple

try:  # Optional offline fallback
    import reverse_geocoder as _reverse_geocoder  # type: ignore
except Exception:  # pragma: no cover - optional dependency
    _reverse_geocoder = None

try:  # Secondary offline fallback (geonames dataset)
    import geonamescache  # type: ignore
except Exception:  # pragma: no cover - optional dependency
    geonamescache = None

try:  # Online geocoder (requires network)
    from geopy.geocoders import Nominatim  # type: ignore
    from geopy.exc import GeocoderServiceError  # type: ignore
except Exception:  # pragma: no cover - optional dependency
    Nominatim = None  # type: ignore
    GeocoderServiceError = Exception  # type: ignore


@dataclass
class GeoResult:
    city: Optional[str]
    admin: Optional[str]
    country_code: Optional[str]
    display_name: Optional[str] = None


class GeoResolver:
    """Resolve latitude/longitude to human readable location with caching."""

    def __init__(self, cache_path: Path, min_interval: float = 1.1) -> None:
        self._cache_path = cache_path
        self._cache_lock = threading.Lock()
        self._cache: Dict[str, Dict] = {}
        self._load_cache()

        self._reverse = None
        self._geo = None
        self._geo_lock = threading.Lock()
        self._last_query = 0.0
        self._min_interval = min_interval
        self._geonames_lock = threading.Lock()
        self._geonames_cities: Optional[List[Tuple[float, float, Dict]]] = None

    def resolve(self, lat: float, lon: float) -> Optional[GeoResult]:
        key = self._cache_key(lat, lon)
        cached = self._cache_get(key)
        if cached:
            return self._dict_to_result(cached)

        result = self._resolve_offline(lat, lon)
        if result is None:
            result = self._resolve_online(lat, lon)

        if result:
            self._cache_set(key, result)
        return result

    # -- cache helpers --------------------------------------------------
    def _cache_key(self, lat: float, lon: float) -> str:
        return f"{round(lat, 4)}:{round(lon, 4)}"

    def _load_cache(self) -> None:
        try:
            if self._cache_path.exists():
                self._cache = json.loads(self._cache_path.read_text())
        except Exception:
            self._cache = {}

    def _cache_get(self, key: str) -> Optional[Dict]:
        with self._cache_lock:
            return self._cache.get(key)

    def _cache_set(self, key: str, result: GeoResult) -> None:
        data = {
            'city': result.city,
            'admin': result.admin,
            'country_code': result.country_code,
            'display_name': result.display_name,
            'ts': time.time(),
        }
        with self._cache_lock:
            self._cache[key] = data
            try:
                self._cache_path.parent.mkdir(parents=True, exist_ok=True)
                tmp = self._cache_path.with_suffix('.tmp')
                tmp.write_text(json.dumps(self._cache, ensure_ascii=False, indent=2))
                tmp.replace(self._cache_path)
            except Exception:
                pass

    # -- offline lookup -------------------------------------------------
    def _resolve_offline(self, lat: float, lon: float) -> Optional[GeoResult]:
        result = self._resolve_offline_reverse_geocoder(lat, lon)
        if result:
            return result
        return self._resolve_offline_geonames(lat, lon)

    def _resolve_offline_reverse_geocoder(self, lat: float, lon: float) -> Optional[GeoResult]:
        if _reverse_geocoder is None:
            return None
        try:
            if self._reverse is None:
                self._reverse = _reverse_geocoder.RGeocoder(mode=2, verbose=False)
            data = self._reverse.query([(lat, lon)])
        except Exception:
            return None
        if not data:
            return None
        entry = data[0]
        try:
            entry_lat = float(entry.get('lat') or entry.get('latitude'))
            entry_lon = float(entry.get('lon') or entry.get('longitude'))
        except (TypeError, ValueError):
            entry_lat = entry_lon = None
        if entry_lat is not None and entry_lon is not None:
            dist_km = self._haversine_km(lat, lon, entry_lat, entry_lon)
            if dist_km > 150:  # reject if more than ~150 km away
                return None
        city = entry.get('name') or None
        admin = entry.get('admin1') or entry.get('admin2') or None
        cc = (entry.get('cc') or '').upper() or None
        return GeoResult(city=city, admin=admin, country_code=cc)

    def _resolve_offline_geonames(self, lat: float, lon: float) -> Optional[GeoResult]:
        if geonamescache is None:
            return None
        with self._geonames_lock:
            if self._geonames_cities is None:
                try:
                    gc = geonamescache.GeonamesCache()
                    cities = []
                    countries = gc.get_countries()
                    subdivisions = gc.get_subdivisions()
                    for city in gc.get_cities().values():
                        try:
                            c_lat = float(city['latitude'])
                            c_lon = float(city['longitude'])
                        except (KeyError, ValueError):
                            continue
                        country_code = city.get('countrycode')
                        admin_code = city.get('admin1code')
                        admin_name = None
                        if admin_code and country_code:
                            key = f"{country_code}.{admin_code}"
                            admin = subdivisions.get(key)
                            if admin:
                                admin_name = admin.get('name')
                        country = countries.get(country_code.upper()) if country_code else None
                        cities.append(
                            (
                                c_lat,
                                c_lon,
                                {
                                    'name': city.get('name'),
                                    'admin': admin_name,
                                    'country_code': country_code.upper() if country_code else None,
                                    'country_name': country.get('name') if country else None,
                                },
                            )
                        )
                    self._geonames_cities = cities
                except Exception:
                    self._geonames_cities = []
            cities = self._geonames_cities or []
        if not cities:
            return None
        best = None
        best_dist = float('inf')
        for c_lat, c_lon, info in cities:
            dist = self._haversine_sq(lat, lon, c_lat, c_lon)
            if dist < best_dist:
                best_dist = dist
                best = info
        if best is None:
            return None
        return GeoResult(
            city=best.get('name'),
            admin=best.get('admin') or best.get('country_name'),
            country_code=best.get('country_code'),
        )

    @staticmethod
    def _haversine_km(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
        phi1 = math.radians(lat1)
        phi2 = math.radians(lat2)
        d_phi = math.radians(lat2 - lat1)
        d_lambda = math.radians(lon2 - lon1)
        sin_dphi = math.sin(d_phi / 2.0)
        sin_dlambda = math.sin(d_lambda / 2.0)
        a = sin_dphi * sin_dphi + math.cos(phi1) * math.cos(phi2) * sin_dlambda * sin_dlambda
        c = 2 * math.atan2(math.sqrt(a), math.sqrt(max(0.0, 1 - a)))
        return 6371.0 * c

    # -- online lookup --------------------------------------------------
    def _resolve_online(self, lat: float, lon: float) -> Optional[GeoResult]:
        if Nominatim is None:
            return None
        with self._geo_lock:
            if self._geo is None:
                try:
                    self._geo = Nominatim(user_agent='holiday-blackbox', timeout=6)
                except Exception:
                    self._geo = None
            geocoder = self._geo
        if geocoder is None:
            return None

        wait = self._min_interval - (time.time() - self._last_query)
        if wait > 0:
            time.sleep(wait)
        try:
            location = geocoder.reverse((lat, lon), language='en', exactly_one=True)
        except GeocoderServiceError:
            return None
        finally:
            self._last_query = time.time()

        if not location:
            return None
        address = getattr(location, 'raw', {}).get('address', {})
        city = self._extract_city(address)
        admin = self._extract_admin(address)
        cc = (address.get('country_code') or '').upper() or None
        display = getattr(location, 'address', None)
        return GeoResult(city=city, admin=admin, country_code=cc, display_name=display)

    @staticmethod
    def _extract_city(address: Dict[str, str]) -> Optional[str]:
        for key in ('city', 'town', 'village', 'municipality', 'hamlet', 'locality', 'suburb'):
            value = address.get(key)
            if value:
                return value
        return address.get('county') or None

    @staticmethod
    def _extract_admin(address: Dict[str, str]) -> Optional[str]:
        for key in ('state', 'region', 'province', 'state_district'):
            value = address.get(key)
            if value:
                return value
        return address.get('county') or None

    @staticmethod
    def _dict_to_result(data: Dict) -> GeoResult:
        return GeoResult(
            city=data.get('city'),
            admin=data.get('admin'),
            country_code=data.get('country_code'),
            display_name=data.get('display_name'),
        )
