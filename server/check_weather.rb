# Self-check for the stale-weather fallback. Run: docker exec -i server-dash-1 ruby < check_weather.rb
require "/app/app.rb"
def fetch_weather = nil # simulate BOM being down

y, t = Date.today - 1, Date.today
@weather = { now: 9, feels: 7, at: Time.now - 7200,
             days: [y, t, t + 1, t + 2].map { |d| { day: d, text: "Rain #{d.day}", min: d.day, max: d.day + 10, rain: "50%", icon: 12 } } }
w = weather
raise "should be stale" unless w[:stale]
raise "today wrong" unless w[:min] == t.day && w[:text] == "Rain #{t.day}" # yesterday must not be shown as today
raise "days wrong" unless w[:days].map { |d| d[:day] } == [t + 1, t + 2]
labels = TEMPLATE.result_with_hash(now: Time.now, weather: w, trains: []).scan(/as of [^<]*/)
raise "label missing" unless labels.size == 1
@weather[:at] = Time.now - 90_000
raise "should expire after a day" unless weather.nil?
puts "OK #{labels.inspect}"
