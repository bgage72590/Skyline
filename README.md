# Skyline

A native macOS weather app (SwiftUI, macOS 14+) with an Apple-Weather-style main window **and** a
menu bar extra in one bundle. Forecasts are a weighted blend of several free models plus the official
National Weather Service forecast; radar is real NEXRAD (US) or RainViewer (global) on an
interactive MapKit map with an animated timeline. No API keys, nothing paid.

## Build / install

```bash
./build-app.sh            # swift build (release) → build/Skyline.app → sign ("Skyline Local Signing") →
                          # quit running copy → replace /Applications/Skyline.app → launch →
                          # zip to iCloud Drive/Skyline/Skyline.zip
swift build && swift test # dev loop
```

Options: `--no-install`, `--no-launch`, `--no-zip`, `--native` (skip the universal arm64+x86_64 attempt).

The app is signed with a self-signed certificate kept in the build Mac's login keychain ("Skyline Local
Signing", created once by `build-app.sh`; no Developer ID). Every build has the same designated
requirement, so Location permission survives updates.

### Installing on other Macs (verified)

The iCloud zip is only a transport: anyone who can edit that folder could swap it. So other Macs install
with `scripts/install-verified.sh`, which unzips to a temp folder, checks the app is signed by the build
Mac's certificate (`identifier "com.briangage.Skyline" and certificate leaf = H"<sha1>"`), and only then
replaces `/Applications/Skyline.app` and clears quarantine. Anything else (ad-hoc, re-signed, modified) is
refused and nothing is touched.

One-time setup per Mac. Copy the script there **outside iCloud** (AirDrop, USB stick or `scp`), then:

```bash
mkdir -p ~/bin && cp install-verified.sh ~/bin/skyline-install && chmod +x ~/bin/skyline-install
```

After each new build has synced:

```bash
~/bin/skyline-install                      # from iCloud Drive/Skyline/Skyline.zip
~/bin/skyline-install --verify-only ~/Downloads/Skyline.zip   # check only
```

The pinned certificate hash is the `CERT_SHA1` line in the script (`build-app.sh` prints the current one).
If the certificate is ever re-created, update that line and copy the script to each Mac again.
`build-app.sh` no longer puts an `install.sh` into iCloud Drive; an old one left there is unverified,
so delete it by hand and don't run it.

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
| US official forecast | **NWS api.weather.gov** `/points` → `/forecast` + `/forecast/hourly` | Forecaster-edited National Blend of Models, bias-corrected locally. Requires a User-Agent with a contact: `Skyline/1.0 (Brian.gage@gmail.com)` is sent only to api.weather.gov; every other host gets plain `Skyline/1.0` (`URLSessionHTTPClient.userAgent(for:)`). |
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


## Radar and forecast extras (batch 5)

* **Future radar.** In the US (NEXRAD), the loop continues past "Now" with up to 2 h of NOAA HRRR
  simulated reflectivity from the Iowa Environmental Mesonet. Those frames are labelled "+N min ·
  Forecast", outlined in purple, and marked on the timeline; the legend says they're a model. Toggle:
  "Future radar (model)" in the radar options (saved as `radarFuture`, default on).
* **Rainfall totals.** The expanded radar's Layer picker (US only) swaps the loop for MRMS 1-hour or
  24-hour rainfall totals (radar + gauges, IEM tiles), with a legend in your precipitation unit.
* **Outside the US** (decided by a border outline and the saved country, so Toronto, Windsor or Juárez
  aren't treated as US): RainViewer radar, no NWS requests, no HRRR. A 404 from NWS `/points` is
  remembered for a week so a border point isn't asked again every refresh.
* **Severe-storm outlook.** For the lower 48, the SPC Day 1/2 categorical outlook at your point shows
  under the big temperature ("Slight risk of severe storms today (level 2 of 5)") from Marginal up, and
  in the briefing line.
* **Snow.** Snowfall totals from the models are blended; snow days show the expected total in the 10-day
  list, and the rain/snow icon follows the blended snow-to-water ratio and temperature (NWS wording wins
  where it exists).
* **Model comparison.** "Model Comparison" (below Forecast Confidence) charts each model's next 48 h of
  temperature, NWS dashed, the Skyline blend in white. A Best Match that copies GFS/HRRR is one line.

## Notifications and Focus

Extreme warnings are sent as *time-sensitive*. Without Apple's critical-alerts entitlement (which needs
a Developer ID and Apple's approval, and which Skyline does not request) macOS lets a time-sensitive
notification through Focus **only if** you allow it: System Settings › Notifications › Skyline › "Allow
time-sensitive notifications", and in each Focus, Skyline (or time-sensitive notifications) must be
allowed. With the self-signed build this may not be offered at all; nothing can break through "Do Not
Disturb" silently. Treat Skyline as a convenience, not your only warning source.

## QA and measurement hooks (hidden launch arguments)

All are inert unless passed on the command line (`open -a Skyline --args -Hook value`, or the binary
directly); none is settable from the UI.

| Hook | Effect |
|---|---|
| `-SkylineOpenRadar YES` | Expand the radar at launch |
| `-SkylinePlayRadar YES` | Start radar playback at launch |
| `-SkylineStressTest <s>` / `-SkylineStressSeed <n>` / `-SkylineStressQuit YES` | In-process radar stress test; quit when done |
| `-SkylineScrollTest YES` | Scroll-position preservation check (`[scrolltest]`) |
| `-SkylineHitTest YES` | Map ignores scroll over the forecast column (`[hittest]`) |
| `-SkylineScrollToCard outlook\|notes\|models` | Scroll the forecast column to that card after ~3 s |
| `-SkylineMenuMaxHeight <pt>` | Cap the menu-bar dropdown height (overflow/scroll check) |
| `-SkylineOpenModule <name>` | Open a module detail at launch |
| `-SkylineCloseMainWindowAfter <s>` | Close the main window after N s (menu-bar-only measurement) |
| `-SkylineWindowSize WxH` | Main window size for measurements |
| `-SkylineSnapshotMenu <path>` | Render the menu-bar label to a PNG |
| `-SkylineNotifyPreview YES` | Print the notification plan (all kinds on); nothing is sent or remembered |
| `-SkylineSimulateOffline YES\|cold` | Network always fails: `YES` keeps the disk cache (stale banner), `cold` starts empty (error states) |
| `-SkylineNowcastScrub <min>` | Pre-select a point on the next-hour rain chart (screenshot) |
| `-SkylineDemoRain YES` / `-SkylineDemoAlert YES` / `-SkylineDemoAccuracy YES` | Synthetic rain, alert or accuracy data for screenshots |
| `-SkylineLogLayout YES` | Log detail-area width and layout switches |
| `-SkylineTileBudget <n>` / `-SkylineDecodedCacheMB <n>` | Radar memory experiments (tile budget per map, decoded-tile cache) |


## Modules

Tapping the hourly or 10-day module, a day row, or a tile opens an in-window detail panel (Apple's
module expansion): a 10-day picker, a Swift Charts hourly chart for that metric, and a summary. The
Confidence module shows each source's high/low and its blend weight for the chosen day. Launch
arguments for QA screenshots: `-SkylineOpenRadar YES`, `-SkylineOpenModule <conditions|uv|wind|…>`.
Radar stress test (in-process, no synthetic input): `-SkylineOpenRadar YES -SkylineStressTest <seconds>
-SkylineStressQuit YES` expands/collapses, plays/pauses, scrubs, zooms and changes opacity, logging
`[stress]` progress and memory to stdout. Overscan hit-test: `-SkylineHitTest YES` (wide layout)
checks the map ignores scroll over the forecast column (`[hittest] … PASS|FAIL`). The radar opacity slider (card and expanded map) is saved
as `radarOpacity.v2` (default 60 %, adjustable 5–100 %); the radar is drawn with normal (source-over) compositing over a
full-emphasis dark map, so roads and town names read through the rain. The idle radar keeps only the shown frame in
memory; the whole loop is loaded when you press Play or scrub (Play during loading is queued: "starts at 100 %").
Failed radar tiles are retried after a back-off, after wake and when the network returns. With the main window closed,
its content (map, radar, background) is torn down and only the menu-bar location refreshes, every 30 min or more.
* CoreLocation uses one-shot `requestLocation()` at kilometre accuracy, not continuous updates.
