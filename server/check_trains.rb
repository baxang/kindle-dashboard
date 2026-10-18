# Self-check for the walking-time filter. Run: docker exec -i server-dash-1 ruby < check_trains.rb
require "/app/app.rb"
now = Time.now
def trains = [1, 2, 3, 5, 10, 20, 30, 40, 50].map { |m| { dep: Time.now + m * 60 + 30, arrivals: [nil] * (TRAIN_STOPS.size - 1) } }
shown = html(now).scan(%r{<b>(\d\d:\d\d)</b>}).flatten
want = [3, 5, 10, 20, 30].map { |m| (now + m * 60 + 30).strftime("%H:%M") }
raise "got #{shown}, want #{want}" unless shown == want
puts "OK #{shown}"
