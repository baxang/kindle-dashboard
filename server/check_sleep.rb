# Self-check for the Kindle sleep schedule and night screen. Run: docker exec -i server-dash-1 ruby < check_sleep.rb
require "/app/app.rb"
at = ->(s) { Time.parse("#{s} +11:00") } # 2026-10-19 is a Monday
{ "2026-10-19 06:00:20" => 0, "2026-10-19 10:59:30" => 0,            # weekday morning: awake
  "2026-10-19 11:00:15" => 585, "2026-10-19 11:09:58" => 602,       # every 10 min; an early wake skips to the mark after
  "2026-10-24 08:00:15" => 585,                                      # Saturday morning: every 10 min
  "2026-10-19 22:50:15" => 585, "2026-10-19 23:00:15" => 25_185,    # last refresh at 23:00, then 06:00
  "2026-10-20 02:13:00" => 13_620 }                                  # woken in the night (power button): back to sleep
  .each { |t, want| got = sleep_secs(at.(t)); raise "#{t}: #{got}, want #{want}" unless got == want }
File.write(STAY_AWAKE, "")
raise "awake file ignored" unless sleep_secs(at.("2026-10-19 13:00:00")) == 0
File.delete(STAY_AWAKE)

render = ->(**o) { TEMPLATE.result_with_hash(now: at.("2026-10-20 14:30:00"), batt: nil, weather: nil, transfers: nil, back: nil,
                                             trains: { list: [{ dep: at.("2026-10-20 14:40:00"), arrivals: [] }] * 5, notes: [] }, **o) }
raise "live page lost its clock" unless render.(live: true).include?(">14:30<")
day = render.(live: false)
raise "stale clock or countdown while asleep" if day =~ /\d+ min|then in|class="time"/ || !day.include?("As of<br>14:30")
night = render.(live: false, back: at.("2026-10-21 06:00:00"))
raise "night page wrong" unless night.include?("Next update<br>06:00") && night.include?("Wed 21 October") && night.include?("<table")
puts "OK"
