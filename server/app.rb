require "erb"
require "ferrum"
require "json"
require "mini_magick"
require "net/ftp"
require "net/http"
require "rexml/document"
require "time"
require "webrick"

PORT = Integer(ENV.fetch("PORT", 8080))
W, H = 758, 1024 # Paperwhite 2 screen, portrait
TEMPLATE = ERB.new(File.read(File.join(__dir__, "dash.erb")))

# Locations come from .env; see .env.example.
BOM_FORECAST_FILE, BOM_FORECAST_AREA = ENV.fetch("BOM_FORECAST_FILE"), ENV.fetch("BOM_FORECAST_AREA")
BOM_OBS_FILE, BOM_STATION = ENV.fetch("BOM_OBS_FILE"), ENV.fetch("BOM_STATION")
# "id:Label,id:Label,...": the first stop is where you board, the last is the query destination,
# and every stop after the first gets an arrival-time column.
JOURNEY1_STOPS = ENV.fetch("JOURNEY1_STOPS").split(",").map { |s| s.strip.split(":", 2) }
JOURNEY1_WALK_MIN = Integer(ENV.fetch("JOURNEY1_WALK_MIN", 3)) # minutes to walk to the first stop; trains sooner than this can't be caught
# Optional second trip, "from,change,to" in the same format. Any mode is allowed, so trackwork buses show up.
JOURNEY2_STOPS = ENV["JOURNEY2_STOPS"]&.split(",")&.map { |s| s.strip.split(":", 2) }
JOURNEY2_WALK_MIN = Integer(ENV.fetch("JOURNEY2_WALK_MIN", 3))
LOW_BATT = Integer(ENV.fetch("LOW_BATT", 20)) # at or below this %, and not charging, the dashboard shows a low-battery icon
BATT_LOG = "/data/battery.csv" # one line per Kindle fetch: time,percent,charging,mAh left,average mA
STAY_AWAKE = "/data/awake" # touch server/data/awake to keep the Kindle awake (for SSH); it takes effect at its next wake

# Seconds the Kindle should sleep after this fetch; 0 = stay awake, refresh every minute and react to taps.
# Asleep it draws ~4 mA instead of ~17, but each wake costs ~15 s of Wi-Fi reconnect, so sleeps are long or none.
# Weekdays 06-11 every minute; 23-06 one sleep, showing the 06:00 departures and forecast (NIGHT); otherwise every 10 min.
NIGHT = 3600 # a sleep longer than this renders the page as of the wake time
def sleep_secs(now = Time.now)
  return 0 if File.exist?(STAY_AWAKE) || ((1..5) === now.wday && (6...11) === now.hour)
  t = now + 60 # a Kindle that wakes a few seconds early mustn't get a tiny sleep
  nxt = if t.hour == 23 || t.hour < 6 then d = t.hour == 23 ? t.to_date + 1 : t.to_date; Time.new(d.year, d.month, d.day, 6)
        else Time.at((t.to_i / 600 + 1) * 600) # Sydney's offset is whole hours, so these are :00, :10, ... local
        end
  (nxt - now).round
end

# Refetched every 10 min. If a fetch fails, the last good result is shown for up to a day,
# marked stale after 30 min so the screen says "as of HH:MM".
def weather(today = Date.today)
  fetch_weather if !@weather || Time.now - @weather[:at] > 600
  return unless @weather && Time.now - @weather[:at] < 86_400
  # today is passed per render, so a cache that crosses midnight doesn't show yesterday as today
  t = @weather[:days].find { |d| d[:day] == today }
  @weather.merge(text: t&.dig(:text), min: t&.dig(:min), max: t&.dig(:max),
                 days: @weather[:days].select { |d| d[:day] > today }.first(5), stale: Time.now - @weather[:at] > 1800)
end

# BOM's anonymous FTP is its documented channel for automated downloads. One login fetches all files.
# A file is downloaded only when its modification time has changed: the forecast is reissued a few times a day,
# the readings about every 10 min.
def bom_get(*files)
  @bom ||= {}
  Net::FTP.open("ftp.bom.gov.au", username: "anonymous", open_timeout: 5, read_timeout: 15) do |ftp|
    files.map do |f|
      path = "/anon/gen/fwo/#{f}.xml"
      mtime = ftp.mtime(path)
      @bom[f] = { mtime:, doc: REXML::Document.new(ftp.getbinaryfile(path, nil)) } unless @bom.dig(f, :mtime) == mtime
      @bom[f][:doc]
    end
  end
end

def bom_val(node, type) = node.elements[".//*[@type='#{type}']"]&.text

def fetch_weather
  forecast, readings = bom_get(BOM_FORECAST_FILE, BOM_OBS_FILE)
  area = forecast.elements["//area[@description='#{BOM_FORECAST_AREA}']"] or raise "no forecast for #{BOM_FORECAST_AREA}"
  days = area.get_elements("forecast-period").map do |p|
    v = ->(type) { bom_val(p, type) }
    { day: Date.parse(p.attributes["start-time-local"]), text: v.("precis")&.chomp("."), icon: v.("forecast_icon_code")&.to_i,
      min: v.("air_temperature_minimum")&.to_i, max: v.("air_temperature_maximum")&.to_i, # today's go missing later in the day
      rain: v.("probability_of_precipitation") }
  end
  obs = readings.elements["//station[@description='#{BOM_STATION}']/period"] or raise "no readings for #{BOM_STATION}"
  reading = ->(type) { Float(bom_val(obs, type)).round } # a missing reading fails the fetch, keeping the last good one
  @weather = { now: reading.("air_temperature"), feels: reading.("apparent_temp"), days:, at: Time.now }
rescue => e
  warn "weather: #{e.class}: #{e.message}" # keep the previous @weather
end

def tfnsw(path, **params)
  uri = URI("https://api.transport.nsw.gov.au/v1/tp/#{path}")
  uri.query = URI.encode_www_form(outputFormat: "rapidJSON", coordOutputFormat: "EPSG:4326", version: "10.2.1.42", **params)
  req = Net::HTTP::Get.new(uri, "Authorization" => "apikey #{ENV.fetch("NSW_TRANSPORT_OPENDATA_API")}")
  JSON.parse(Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 15) { |h| h.request(req).body })
end

def at(point, kind) = Time.parse(point["#{kind}TimeEstimated"] || point["#{kind}TimePlanned"]).localtime

def trips(from, to, from_time, **via) = tfnsw("trip", depArrMacro: "dep", itdDate: from_time.strftime("%Y%m%d"), itdTime: from_time.strftime("%H%M"),
                                              type_origin: "any", name_origin: from, type_destination: "any",
                                              name_destination: to, calcNumberOfTrips: 8, TfNSWTR: true, **via)["journeys"] # 10 is ~2x slower; 8 leaves spares after the walk filter

def station(point) = point["name"].split(",").first.delete_suffix(" Station")

# Ids of alerts in effect now with a fixed end, i.e. trackwork ("Sunday 18 October: buses replace trains ...").
# Open-ended ones are news or noise ("Bus changes from 21 June"). The trip API omits dates, so they come from
# the alerts feed, refetched every 10 min; on failure the last list is kept. Only line alerts for trains (1) and
# Metro (2), one mode per request: a fraction of the all-modes feed. Bus, coach and ferry alerts are left out.
def trackwork_ids
  if !@trackwork || Time.now - @trackwork[:at] > 600
    infos = [1, 2].flat_map do |mode| # a mode with no alerts comes back as "infos": {}
      tfnsw("add_info", filterPublicationStatus: "current", filterInfoType: "lineInfo", filterMOTType: mode).fetch("infos").fetch("current", [])
    end
    now = Time.now
    ids = infos.select { |i| i.dig("timestamps", "validity").to_a.any? { |v| !v["isOpenEnd"] && Time.parse(v["from"]) <= now && now < Time.parse(v["to"]) } }
    @trackwork = { at: now, ids: ids.map { |i| i["id"] }.to_set } # ponytail: both trip threads may refetch at once; harmless
  end
  @trackwork[:ids]
rescue => e
  warn "alerts: #{e.class}: #{e.message}"
  @trackwork ? @trackwork[:ids] : Set.new
end

# Trackwork from every journey the query returned: replacement buses, and line alerts that are trackwork_ids.
# Per-trip messages ("Running late") are left out; estimates already cover them.
def notices(journeys)
  legs = journeys.flat_map { |j| j["legs"] }
  buses = legs.select { |l| l.dig("transportation", "product", "name").to_s =~ /temporary|replacement/i }
              .map { |l| "Buses replace trains #{station(l["origin"])}–#{station(l["destination"])}" }
  alerts = legs.flat_map { |l| l["infos"].to_a }.select { |i| i["type"] == "lineInfo" && trackwork_ids.include?(i["id"]) }
  (buses + alerts.map { |i| i.dig("properties", "smsText") }).compact.uniq
end

# Next trains from the first stop that run through to the last one, with arrival times at the other stops.
def trains(from_time = Time.now)
  journeys = trips(JOURNEY1_STOPS[0][0], JOURNEY1_STOPS[-1][0], from_time)
  list = journeys.filter_map do |j|
    leg = j["legs"][0]
    next unless j["legs"].size == 1 && leg.dig("transportation", "product", "class") == 1 # one train, no change
    arrive = ->(id) { s = leg["stopSequence"].to_a.find { |s| s.dig("parent", "id") == id }; s && at(s, "arrival") }
    { dep: at(leg["origin"], "departure"), arrivals: JOURNEY1_STOPS.drop(1).map { |id, _| arrive.(id) } }
  end
  { list: list.uniq { |t| t[:dep] }.sort_by { |t| t[:dep] }, notes: notices(journeys) }
rescue => e
  warn "trains: #{e.class}: #{e.message}"
  nil
end

# Next trips on the second journey: when the first train leaves, when the onward service leaves the change stop, and arrival.
def transfers(from_time = Time.now)
  from, via, to = JOURNEY2_STOPS.map(&:first)
  journeys = trips(from, to, from_time, type_via: "any", name_via: via)
  list = journeys.map do |j|
    legs = j["legs"].reject { |l| l.dig("transportation", "product", "class").to_i >= 99 } # walks between platforms
    onward = legs.find { |l| l.dig("origin", "parent", "id") == via } || legs[1] # planner may change elsewhere; nil if one train runs through
    { dep: at(legs[0]["origin"], "departure"), line: legs[0].dig("transportation", "disassembledName"),
      change: onward && at(onward["origin"], "departure"), arr: at(legs[-1]["destination"], "arrival"),
      bus: legs.any? { |l| l.dig("transportation", "product", "class") == 5 } } # 5 = bus; Metro (2) or ferry is not a bus
  end
  list = list.uniq { |t| t[:dep] }.sort_by { |t| t[:dep] }
  # Drop trips that a later one arrives no later than: the planner likes one-seat rides, e.g. a T1 the long way through the city.
  list = list.reject.with_index { |t, i| list[i + 1..].any? { |u| u[:arr] <= t[:arr] } }
  { list:, notes: notices(journeys) }
rescue => e
  warn "transfers: #{e.class}: #{e.message}"
  nil
end

# sleep: how long the Kindle will show this page (0 = it refreshes every minute).
# Overnight (sleep > NIGHT) the page is for the morning: departures and forecast as of the wake time.
def html(now = Time.now, batt: nil, sleep: 0)
  back = Time.at(((now + sleep).to_i + 30) / 60 * 60) if sleep > NIGHT # nearest minute: sleep was worked out a moment before now
  from = back || now
  direct, change = [Thread.new { trains(from) }, Thread.new { transfers(from) if JOURNEY2_STOPS }].map(&:value) # in parallel: each query takes 1-3 s
  catchable = ->(r, walk) { r&.merge(list: r[:list].reject { |t| t[:dep] - from < walk * 60 }.first(6)) }
  TEMPLATE.result_with_hash(now:, batt:, live: sleep.zero?, back:, weather: weather(from.to_date),
                            trains: catchable.(direct, JOURNEY1_WALK_MIN), transfers: catchable.(change, JOURNEY2_WALK_MIN))
end

def render_png(query = "")
  browser = Ferrum::Browser.new(window_size: [W, H], process_timeout: 30, timeout: 30, # page load includes data fetches
                                browser_options: { "no-sandbox" => nil, "disable-dev-shm-usage" => nil })
  browser.resize(width: W, height: H) # window_size includes browser chrome; this sets the viewport
  browser.goto("http://127.0.0.1:#{PORT}/?#{query}")
  img = MiniMagick::Image.read(browser.screenshot(encoding: :binary))
  # eips on old firmware wants plain 8-bit single-channel greyscale PNG
  img.combine_options do |c|
    c.alpha "off"
    c.colorspace "Gray"
    c.depth 8
    c.define "png:color-type=0"
  end
  img.to_blob
ensure
  browser&.quit
end

if $0 == __FILE__ # the check_*.rb scripts require this file without starting the server
  server = WEBrick::HTTPServer.new(Port: PORT)
  server.mount_proc("/") do |req, res|
    batt = Integer(req.query["batt"], exception: false)
    res.content_type = "text/html; charset=utf-8"
    res.body = html(batt: (if req.query["chg"] == "1" then :charging elsif batt && batt <= LOW_BATT then :low end), sleep: Integer(req.query["sleep"], exception: false) || 0)
  end
  server.mount_proc("/dash.png") do |req, res|
    if (batt = Integer(req.query["batt"], exception: false))
      begin
        mah, ma = %w[mah ma].map { |k| Integer(req.query[k], exception: false) }
        File.write(BATT_LOG, "#{Time.now.iso8601},#{batt},#{req.query["chg"]},#{mah},#{ma}\n", mode: "a")
      rescue => e
        warn "battery log: #{e.message}"
      end
    end
    secs = sleep_secs
    res["X-Sleep"] = secs.to_s # run.sh reads this with wget -S
    res.content_type = "image/png"
    res.body = render_png("#{req.query_string}&sleep=#{secs}") # a sleeping screen gets clock times, not "in N min"
  end
  %w[INT TERM].each { |s| trap(s) { server.shutdown } }
  server.start
end
