# Self-check for the walking-time filter and the transfer parsing. Run: docker exec -i server-dash-1 ruby < check_trains.rb
require "/app/app.rb"
now = Time.at(Time.now.to_i) # whole seconds, to survive the ISO 8601 round trip below

if JOURNEY2_STOPS
  # Express train to the change stop, a walk between platforms, a train, then a replacement bus.
  from, via, to = JOURNEY2_STOPS.map(&:first)
  pt = ->(id, m, kind) { { "name" => "#{id} Station, Stand C, X", "parent" => { "id" => id }, "#{kind}TimePlanned" => (now + m * 60).utc.iso8601 } }
  leg = ->(cls, line, a, am, b, bm, product = "Trains") { { "transportation" => { "disassembledName" => line, "product" => { "class" => cls, "name" => product } },
                                                             "origin" => pt.(a, am, "departure"), "destination" => pt.(b, bm, "arrival") } }
  journey = { "legs" => [leg.(1, "CCN", from, 10, via, 30), leg.(100, nil, via, 30, via, 33), leg.(1, "T6", via, 40, "Lid", 46),
                         leg.(5, "63T1", "Lid", 50, to, 70, "Temporary buses")] }
  define_method(:trips) { |*, **| [journey] }
  got = transfers
  want = { list: [{ dep: now + 600, line: "CCN", change: now + 2400, arr: now + 4200, bus: true }], notes: ["Buses replace trains Lid–#{to}"] }
  raise "transfers: got #{got}, want #{want}" unless got == want
  puts "OK transfers"
end

def trains = { list: [1, 2, 3, 5, 10, 20, 30, 40, 50].map { |m| { dep: Time.now + m * 60 + 30, arrivals: [nil] * (JOURNEY1_STOPS.size - 1) } }, notes: [] }
def transfers = nil
page = html(now)
shown = page.scan(%r{<b>(\d\d:\d\d)</b>}).flatten
want = [3, 5, 10].map { |m| (now + m * 60 + 30).strftime("%H:%M") }
raise "got #{shown}, want #{want}" unless shown == want
raise "no 'then in' line" unless page.include?("then in 20, 30, 40 min")
puts "OK #{shown}, then in 20, 30, 40 min"

# Long gaps: once any later train is an hour or more away, the "then" line shows clock times.
def trains = { list: [3, 5, 10, 20, 30, 90].map { |m| { dep: Time.now + m * 60 + 30, arrivals: [nil] * (JOURNEY1_STOPS.size - 1) } }, notes: [] }
want = "then " + [20, 30, 90].map { |m| (now + m * 60 + 30).strftime("%H:%M") }.join(", ")
raise "no '#{want}' line" unless html(now).include?(want)
puts "OK #{want}"

# Alerts: only ones in effect now with a fixed end count as trackwork; open-ended news and next week's work don't.
alert = ->(id, from, to, open = false) { { "id" => id, "timestamps" => { "validity" => [{ "from" => from.utc.iso8601, "to" => to.utc.iso8601, "isOpenEnd" => open }] } } }
feed = { "infos" => { "current" => [alert.("work", now - 3600, now + 3600), alert.("news", now - 3600, Time.utc(2500), true), alert.("next", now + 86_400, now + 90_000)] } }
define_method(:tfnsw) { |*, **| feed }
@trackwork = nil
raise "trackwork_ids: got #{trackwork_ids.to_a}" unless trackwork_ids == Set["work"]
puts "OK trackwork alerts"
