class Abera::RateLimit
  SCRIPT = <<~LUA.freeze
    local used = redis.call('INCR', KEYS[1])
    if used == 1 then redis.call('EXPIRE', KEYS[1], 120) end
    return used
  LUA

  def self.allowed?(subscription, kind, limit)
    key = "abera:#{subscription.subscription_id}:#{kind}:#{Time.current.to_i / 60}"
    ::Redis::Alfred.with { |connection| connection.eval(SCRIPT, keys: [key], argv: []).to_i <= limit }
  end
end
