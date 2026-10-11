# Skyline

A native macOS weather app (SwiftUI, macOS 14+) with an Apple-Weather-style main window **and** a
menu bar extra in one bundle. Forecasts are a weighted blend of several free models plus the official
National Weather Service forecast; radar is real NEXRAD (US) or RainViewer (global) on an
interactive MapKit map with an animated timeline. No API keys, nothing paid.

## Build / install

```bash
./build-app.sh            # swift build (release) → build/Skyline.app → ad-hoc sign →
                          # quit running copy → replace /Applications/Skyline.app → launch →
                          # zip to iCloud Drive/Skyline/Skyline.zip
swift build && swift test # dev loop
```

Options: `--no-install`, `--no-launch`, `--no-zip`, `--native` (skip the universal arm64+x86_64 attempt).

On another Mac (after iCloud syncs):

```bash
bash ~/Library/Mobile\ Documents/com~apple~CloudDocs/Skyline/install.sh
```

The app is ad-hoc signed (no Developer ID), so every rebuild has a new signature: macOS may ask for
Location permission again after an update.

## Architecture

```
Sources/SkylineCore/      Foundation-only, Sendable, fully unit-tested (also builds on Linux)
  Models/                 WeatherLocation, CurrentConditions, Hourly/DailyForecast, WeatherAlert,
                          AirQuality, WeatherReport, WeatherCondition (WMO → text/SF Symbol), Units
  Parsing/                Open-Meteo (multi-model, unixtime), NWS (points/forecast/hourly/alerts),
                          RainViewer + IEM NEXRAD frame indexes, geocoding, air quality
  Blending/               ForecastBlender (weighted consensus) + Nowcast (15-min precip text)
  Services/               HTTPClient protocol + URLSession impl, ResponseCache (disk, TTL, stale
                          fallback), Endpoints, WeatherService (actor; concurrent fetch, de-dupe)
Sources/Skyline/          macOS app (SwiftUI + MapKit + CoreLocation)
  App/                    @main App: Window "main", Window "radar", MenuBarExtra, Settings
  Stores/                 WeatherStore (@Observable, refresh policy), RadarPlayback (timeline)
  Radar/                  RadarMapView (MKMapView + MKTileOverlay per frame), RadarTileLoader
                          (URLCache, over-zoom crop/upscale beyond native zoom)
  Views/                  Sidebar, detail (hero, hourly, 10-day, tiles), alerts, radar, menu bar
  Support/                LocationProvider, WindowVisibilityReader, formatting & palettes
Tests/SkylineCoreTests/   XCTest with real fixture JSON captured from each API
```

## Data sources and why

| Need | Source | Why |
| --- | --- | --- |
| Global forecast | **Open-Meteo** `/v1/forecast` with `models=best_match,gfs_hrrr,ecmwf_ifs025,gfs_seamless,icon_seamless` | Free, no key, one request returns several models side by side. |
| US official forecast | **NWS api.weather.gov** `/points` → `/forecast` + `/forecast/hourly` | Forecaster-edited National Blend of Models, bias-corrected locally. Requires a User-Agent (set in `URLSessionHTTPClient.userAgent`). |
| Alerts | NWS `/alerts/active?point=` | Authoritative US warnings/watches. |
| Next-2-hours precip | Open-Meteo `minutely_15` | HRRR 15-minute data in the US. |
| Air quality | Open-Meteo Air Quality (CAMS) | Free US AQI, PM2.5, ozone. |
| Search | Open-Meteo geocoding | Free, includes time zones. |
| Radar (US) | **Iowa Environmental Mesonet NEXRAD N0Q** tiles | NOAA radar mosaic at ~1 km, 5-minute frames, sharp to zoom 10+. |
| Radar (global) | **RainViewer** public tiles | Worldwide composite; free tier limits zoom to 7 (Skyline over-zooms). |

### Blending (`ForecastBlender`)

Weighted consensus with a short-range specialist. Averaging independent models beats any single model
on average; weights let the better sources count more:

| Source | Weight |
| --- | --- |
| NWS (US only) | 2.5 |
| NOAA HRRR (US only) | 3.0 up to 18 h, fading linearly to 0.5 at 36 h (data ends ~48 h) |
| Open-Meteo best_match | 2.0 |
| ECMWF IFS | 1.5 |
| GFS, ICON | 1.0 each |

Numeric fields (temperature, apparent temperature, precip probability/amount, wind, humidity, UV) are
weighted means of whichever sources have a value for that hour/day. Daily highs/lows map NWS daytime
periods to that day's high and the preceding night's period to the low. Categorical fields (weather code)
come from the best single source (HRRR for the first 18 h, otherwise best_match) and are then reconciled
with the blended precipitation numbers so the icon agrees with the percentages. The spread between sources
is kept and shown as a "Confidence" tile and per-day "model spread".

## Performance

* No continuous animations anywhere; backgrounds are static gradients.
* One refresh loop (`Task.sleep` with 90 s tolerance so macOS can coalesce timers), default every 15 min.
  It refreshes only the menu-bar location unless the main window is actually visible (occlusion-aware);
  also refreshes after wake.
* All API responses are cached on disk with TTLs (forecast 10 min, NWS 15 min, alerts 5 min, NWS point
  metadata 7 days); stale cache is served when offline. Concurrent requests for a location are de-duplicated.
* Radar: frame timer exists only while playing **and** the radar window is visible; animation just flips
  overlay alpha (tiles come from URLCache, no re-download). The radar preview on the main page is static.
* CoreLocation uses one-shot `requestLocation()` at kilometre accuracy, not continuous updates.
