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
  App/                    @main App: Window "main", MenuBarExtra, Settings (no separate radar window)
  Stores/                 WeatherStore (@Observable, refresh policy), RadarPlayback (timeline)
  Radar/                  RadarMapView (MKMapView + one CALayer per frame), RadarImageCache
                          (URLCache, over-zoom crop/upscale beyond native zoom)
  Views/                  Sidebar, detail (hero, hourly, 10-day, tiles), module detail panels, alerts, radar, menu bar
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
* Radar: frame timer exists only while playing **and** the main window is visible and not occluded,
  and only after every frame's tiles are prefetched. Frames cross-fade by animating CALayer opacity on
  the GPU; tiles are decoded once into memory (disk URLCache behind it) and never re-downloaded per frame.
  Collapsing the expanded map pauses playback, so the inline map tile is idle by default.

## Radar design

The radar lives inline as Apple-Weather-style map module. Click it (or the expand button, the toolbar
map button, or ⇧⌘M) and it grows in place to fill the detail area with a matched-geometry spring;
Esc or the collapse button shrinks it back. The expanded map has pan/zoom, a source picker, opacity,
a legend, play/pause (Space) and a timeline scrubber; the tile has a compact play button and time.

Why not `MKTileOverlay`: re-alpha-ing or swapping tile overlays makes MapKit re-request and redraw
tiles, which flashes blank tiles. Instead a click-through layer view sits over the `MKMapView` with
one `CALayer` per frame (tile sublayers positioned in MapKit map points). On pan the existing tile
layers just move; on zoom the old zoom level's tiles stay up (scaled) until the new level is complete.
A new set of scans (every ~5 min) is built hidden and swapped in only once loaded.

## Modules

Tapping the hourly or 10-day module, a day row, or a tile opens an in-window detail panel (Apple's
module expansion): a 10-day picker, a Swift Charts hourly chart for that metric, and a summary. The
Confidence module shows each source's high/low and its blend weight for the chosen day. Launch
arguments for QA screenshots: `-SkylineOpenRadar YES`, `-SkylineOpenModule <conditions|uv|wind|…>`.
* CoreLocation uses one-shot `requestLocation()` at kilometre accuracy, not continuous updates.
