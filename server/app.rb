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
TRAIN_STOPS = ENV.fetch("TRAIN_STOPS").split(",").map { |s| s.strip.split(":", 2) }

# Refetched every 10 min. If a fetch fails, the last good result is shown for up to a day,
# marked stale after 30 min so the screen says "as of HH:MM".
def weather
  fetch_weather if !@weather || Time.now - @weather[:at] > 600
  return unless @weather && Time.now - @weather[:at] < 86_400
  today = Date.today # recomputed per render, so a cache that crosses midnight doesn't show yesterday as today
  t = @weather[:days].find { |d| d[:day] == today }
  @weather.merge(text: t&.dig(:text), min: t&.dig(:min), max: t&.dig(:max),
                 days: @weather[:days].select { |d| d[:day] > today }.first(5), stale: Time.now - @weather[:at] > 1800)
end

# BOM's anonymous FTP is its documented channel for automated downloads.
def bom_get(file)
  xml = Net::FTP.open("ftp.bom.gov.au", username: "anonymous", open_timeout: 5, read_timeout: 15) do |ftp|
    ftp.getbinaryfile("/anon/gen/fwo/#{file}.xml", nil)
  end
  REXML::Document.new(xml)
end

def fetch_weather
  area = bom_get(BOM_FORECAST_FILE).elements["//area[@description='#{BOM_FORECAST_AREA}']"] or raise "no forecast for #{BOM_FORECAST_AREA}"
  days = area.get_elements("forecast-period").map do |p|
    v = ->(type) { p.elements["*[@type='#{type}']"]&.text }
    { day: Date.parse(p.attributes["start-time-local"]), text: v.("precis")&.chomp("."), icon: v.("forecast_icon_code")&.to_i,
      min: v.("air_temperature_minimum")&.to_i, max: v.("air_temperature_maximum")&.to_i, # today's go missing later in the day
      rain: v.("probability_of_precipitation") }
  end
  obs = bom_get(BOM_OBS_FILE).elements["//station[@description='#{BOM_STATION}']/period"] or raise "no readings for #{BOM_STATION}"
  reading = ->(type) { obs.elements[".//element[@type='#{type}']"].text.to_f.round }
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

# Next trains from the first stop that run through to the last one, with arrival times at the other stops.
def trains(limit)
  journeys = tfnsw("trip", depArrMacro: "dep", type_origin: "any", name_origin: TRAIN_STOPS[0][0], type_destination: "any",
                           name_destination: TRAIN_STOPS[-1][0], calcNumberOfTrips: 6, TfNSWTR: true)["journeys"]
  journeys.filter_map do |j|
    leg = j["legs"][0]
    next unless j["legs"].size == 1 && leg.dig("transportation", "product", "class") == 1 # one train, no change
    arrive = ->(id) { s = leg["stopSequence"].to_a.find { |s| s.dig("parent", "id") == id }; s && at(s, "arrival") }
    { dep: at(leg["origin"], "departure"), arrivals: TRAIN_STOPS.drop(1).map { |id, _| arrive.(id) } }
  end.uniq { |t| t[:dep] }.sort_by { |t| t[:dep] }.first(limit)
rescue => e
  warn "trains: #{e.class}: #{e.message}"
  nil
end

def html = TEMPLATE.result_with_hash(now: Time.now, weather: weather, trains: trains(3))

def render_png
  browser = Ferrum::Browser.new(window_size: [W, H], process_timeout: 30,
                                browser_options: { "no-sandbox" => nil, "disable-dev-shm-usage" => nil })
  browser.resize(width: W, height: H) # window_size includes browser chrome; this sets the viewport
  browser.goto("http://127.0.0.1:#{PORT}/")
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

server = WEBrick::HTTPServer.new(Port: PORT)
server.mount_proc("/") { |_, res| res.content_type = "text/html; charset=utf-8"; res.body = html }
server.mount_proc("/dash.png") { |_, res| res.content_type = "image/png"; res.body = render_png }
%w[INT TERM].each { |s| trap(s) { server.shutdown } }
server.start
