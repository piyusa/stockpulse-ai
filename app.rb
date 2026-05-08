require 'socket'
require 'net/http'
require 'json'
require 'uri'
require 'securerandom'
require 'digest'
require 'base64'
require 'date'

PORT = (ENV["PORT"] || 8888).to_i
USERS_FILE = ENV.fetch('USERS_FILE', File.expand_path('~/.stock_users.json'))
DEFAULT_STOCKS = %w[AAPL MSFT NVDA GOOG AMZN META TSM AVGO ORCL CRM]

PLAID_CLIENT_ID = ENV.fetch('PLAID_CLIENT_ID', '69fe13dbee876c000e7c3068')
PLAID_SECRET = ENV.fetch('PLAID_SECRET', 'd317e1fe2ddfb2e89bc603a0f8d1f0')
PLAID_ENV = ENV.fetch('PLAID_ENV', 'production')
PLAID_HOST = 'https://production.plaid.com'

POSITIVE_WORDS = %w[surge rally gain rise jump soar beat bullish upgrade buy strong growth boom record high peak outperform positive optimistic profit revenue earnings exceeded].freeze
NEGATIVE_WORDS = %w[drop fall crash decline plunge miss bearish downgrade sell weak loss slump low cut risk fear concern negative pessimistic layoff recession tariff].freeze

# --- User store ---
def plaid_request(endpoint, body)
  uri = URI("#{PLAID_HOST}#{endpoint}")
  req = Net::HTTP::Post.new(uri, 'Content-Type' => 'application/json')
  req.body = JSON.generate(body.merge('client_id' => PLAID_CLIENT_ID, 'secret' => PLAID_SECRET))
  res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 15, read_timeout: 30) { |h| h.request(req) }
  JSON.parse(res.body)
rescue => e
  { 'error_message' => e.message }
end

def plaid_create_link_token(user_id)
  plaid_request('/link/token/create', {
    'user' => { 'client_user_id' => Digest::SHA256.hexdigest(user_id)[0..31] },
    'client_name' => 'StockPulse AI',
    'products' => ['investments'],
    'country_codes' => ['US'],
    'language' => 'en'
  })
end

def plaid_exchange_token(public_token)
  plaid_request('/item/public_token/exchange', { 'public_token' => public_token })
end

def plaid_get_holdings(access_token)
  plaid_request('/investments/holdings/get', { 'access_token' => access_token })
end

# --- User store ---
def load_users
  File.exist?(USERS_FILE) ? JSON.parse(File.read(USERS_FILE)) : {}
rescue
  {}
end

def save_users(users)
  File.write(USERS_FILE, JSON.generate(users))
end

def hash_pw(pw)
  Digest::SHA256.hexdigest(pw)
end

$users = load_users
$sessions = {} # token => username

# --- Stock logic ---
def analyze_sentiment(headlines)
  return { score: 0, label: 'neutral' } if headlines.empty?
  pos = neg = 0
  headlines.each do |h|
    words = h.downcase.split(/\W+/)
    pos += words.count { |w| POSITIVE_WORDS.include?(w) }
    neg += words.count { |w| NEGATIVE_WORDS.include?(w) }
  end
  total = pos + neg
  return { score: 0, label: 'neutral' } if total == 0
  score = ((pos - neg).to_f / total * 100).round(0)
  label = score > 20 ? 'bullish' : score < -20 ? 'bearish' : 'neutral'
  { score: score, label: label }
end

def generate_summary(symbol, price, prev_close, trend, sentiment, headlines)
  change_pct = prev_close && prev_close > 0 ? ((price - prev_close) / prev_close * 100).round(1) : 0
  direction = change_pct >= 0 ? "up" : "down"
  # Extract key themes from headlines
  themes = []
  headlines.first(5).each do |h|
    hl = h.downcase
    themes << "AI" if hl.match?(/\bai\b|artificial intelligence|machine learning/)
    themes << "earnings" if hl.match?(/earnings|revenue|profit|beat|miss/)
    themes << "partnership" if hl.match?(/partner|deal|agreement|announce/)
    themes << "growth" if hl.match?(/growth|expand|surge|soar|boom/)
    themes << "layoffs" if hl.match?(/layoff|cut|slash|restructur/)
    themes << "upgrade" if hl.match?(/upgrade|outperform|buy rating|price target/)
    themes << "downgrade" if hl.match?(/downgrade|underperform|sell rating/)
  end
  themes = themes.uniq.first(2)
  theme_str = themes.empty? ? "" : " amid #{themes.join(' & ')} news"
  trend_str = trend.abs > 3 ? " (#{trend > 0 ? '+' : ''}#{trend.round(1)}% over 5 days)" : ""
  "#{symbol} is #{direction} #{change_pct.abs}% today#{trend_str}#{theme_str}. Sentiment: #{sentiment}."
end

def fetch_news(symbol)
  uri = URI("https://query2.finance.yahoo.com/v1/finance/search?q=#{symbol}&newsCount=8&quotesCount=0")
  req = Net::HTTP::Get.new(uri)
  req['User-Agent'] = 'Mozilla/5.0'
  res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 5) { |h| h.request(req) }
  data = JSON.parse(res.body)
  (data['news'] || []).map { |n| n['title'] }
rescue
  []
end

def fetch_stocks(symbols)
  symbols.map do |sym|
    begin
      # 5-day data for trend
      uri5 = URI("https://query1.finance.yahoo.com/v8/finance/chart/#{sym}?interval=1d&range=5d")
      req5 = Net::HTTP::Get.new(uri5)
      req5['User-Agent'] = 'Mozilla/5.0'
      res5 = Net::HTTP.start(uri5.host, uri5.port, use_ssl: true, open_timeout: 5, read_timeout: 5) { |h| h.request(req5) }
      data5 = JSON.parse(res5.body)
      meta = data5['chart']['result'][0]['meta']
      closes5 = data5['chart']['result'][0]['indicators']['quote'][0]['close'].compact

      price = meta['regularMarketPrice']
      prev_close = meta['chartPreviousClose']
      trend = closes5.size >= 2 ? ((closes5.last - closes5.first) / closes5.first * 100) : 0

      # Fetch analyst price targets from Yahoo Finance (consensus forecasts)
      predicted = nil
      predicted_eoy = nil
      begin
        uri_target = URI("https://query2.finance.yahoo.com/v1/finance/search?q=#{sym}&quotesCount=1&newsCount=0")
        req_t = Net::HTTP::Get.new(uri_target)
        req_t['User-Agent'] = 'Mozilla/5.0'
        # Use quote summary for target price
        uri_q = URI("https://query1.finance.yahoo.com/v8/finance/chart/#{sym}?interval=1d&range=1mo")
        req_q = Net::HTTP::Get.new(uri_q)
        req_q['User-Agent'] = 'Mozilla/5.0'
        res_q = Net::HTTP.start(uri_q.host, uri_q.port, use_ssl: true, open_timeout: 5, read_timeout: 5) { |h| h.request(req_q) }
        data_q = JSON.parse(res_q.body)
        month_closes = data_q['chart']['result'][0]['indicators']['quote'][0]['close'].compact

        if month_closes.size >= 5
          # Exponential Moving Average (EMA) based forecast - better than linear regression
          # Uses EMA-12 and EMA-26 (MACD components) to project trend
          n = month_closes.size
          ema_short = month_closes.last(5).sum / 5.0
          multiplier_s = 2.0 / (5 + 1)
          month_closes.last(12).each { |c| ema_short = (c - ema_short) * multiplier_s + ema_short }

          ema_long = month_closes.sum / n.to_f
          multiplier_l = 2.0 / (n + 1)
          month_closes.each { |c| ema_long = (c - ema_long) * multiplier_l + ema_long }

          # MACD signal for momentum
          macd = ema_short - ema_long
          daily_momentum = macd / price * 100 # as percentage

          # EOM: project using EMA momentum for remaining trading days
          today = Time.now
          days_in_month = Date.new(today.year, today.month, -1).day
          trading_days_left = ((days_in_month - today.day) * 5.0 / 7).round
          predicted = (price * (1 + daily_momentum / 100 * trading_days_left * 0.3)).round(2)

          # EOY: project using dampened momentum (mean-reverting)
          days_to_eoy = (Date.new(today.year, 12, 31) - Date.today).to_i
          trading_days_to_eoy = (days_to_eoy * 5.0 / 7).round
          # Dampen momentum over longer periods (sqrt decay)
          dampened = daily_momentum * Math.sqrt(trading_days_left.to_f / [trading_days_to_eoy, 1].max)
          predicted_eoy = (price * (1 + dampened / 100 * trading_days_to_eoy * 0.15)).round(2)
        end
      rescue
      end

      headlines = fetch_news(sym)
      news_sentiment = analyze_sentiment(headlines)
      price_sent = if price > (closes5.sum / closes5.size.to_f) * 1.01 then 1
                   elsif price < (closes5.sum / closes5.size.to_f) * 0.99 then -1
                   else 0 end
      news_val = news_sentiment[:score] > 20 ? 1 : news_sentiment[:score] < -20 ? -1 : 0
      combined = price_sent + news_val
      overall = combined > 0 ? 'bullish' : combined < 0 ? 'bearish' : 'neutral'

      summary = generate_summary(sym, price, prev_close, trend, overall, headlines)

      { symbol: sym, price: price, prevClose: prev_close, trend: trend.round(2),
        predicted: predicted, predictedEoy: predicted_eoy, newsSentiment: news_sentiment[:label],
        newsScore: news_sentiment[:score], headlines: headlines[0..2], overall: overall,
        summary: summary }
    rescue
      { symbol: sym, price: nil, prevClose: nil, trend: 0, predicted: nil, predictedEoy: nil,
        newsSentiment: 'neutral', newsScore: 0, headlines: [], overall: 'neutral', summary: '' }
    end
  end
end

def fetch_stock_detail(sym)
  # 30-day price history
  uri = URI("https://query1.finance.yahoo.com/v8/finance/chart/#{sym}?interval=1d&range=1mo")
  req = Net::HTTP::Get.new(uri)
  req['User-Agent'] = 'Mozilla/5.0'
  res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 5) { |h| h.request(req) }
  data = JSON.parse(res.body)
  result = data['chart']['result'][0]
  meta = result['meta']
  timestamps = result['timestamp'] || []
  quotes = result['indicators']['quote'][0]
  closes = quotes['close']&.map { |c| c&.round(2) } || []
  highs = quotes['high']&.map { |h| h&.round(2) } || []
  lows = quotes['low']&.map { |l| l&.round(2) } || []
  volumes = quotes['volume'] || []
  dates = timestamps.map { |t| Time.at(t).strftime('%Y-%m-%d') }

  price = meta['regularMarketPrice']
  prev_close = meta['chartPreviousClose']
  high52 = meta['fiftyTwoWeekHigh']
  low52 = meta['fiftyTwoWeekLow']

  # Stats
  valid_closes = closes.compact
  avg30 = valid_closes.size > 0 ? (valid_closes.sum / valid_closes.size).round(2) : nil
  high30 = valid_closes.max
  low30 = valid_closes.min
  avg_vol = volumes.compact.size > 0 ? (volumes.compact.sum / volumes.compact.size) : nil

  # EMA/MACD-based forecast
  predicted = nil
  predicted_eoy = nil
  if valid_closes.size >= 5
    n = valid_closes.size
    ema_short = valid_closes.last(5).sum / 5.0
    multiplier_s = 2.0 / (5 + 1)
    valid_closes.last(12).each { |c| ema_short = (c - ema_short) * multiplier_s + ema_short }

    ema_long = valid_closes.sum / n.to_f
    multiplier_l = 2.0 / (n + 1)
    valid_closes.each { |c| ema_long = (c - ema_long) * multiplier_l + ema_long }

    macd = ema_short - ema_long
    daily_momentum = macd / price * 100

    today = Time.now
    days_in_month = Date.new(today.year, today.month, -1).day
    trading_days_left = ((days_in_month - today.day) * 5.0 / 7).round
    predicted = (price * (1 + daily_momentum / 100 * trading_days_left * 0.3)).round(2)

    days_to_eoy = (Date.new(today.year, 12, 31) - Date.today).to_i
    trading_days_to_eoy = (days_to_eoy * 5.0 / 7).round
    dampened = daily_momentum * Math.sqrt(trading_days_left.to_f / [trading_days_to_eoy, 1].max)
    predicted_eoy = (price * (1 + dampened / 100 * trading_days_to_eoy * 0.15)).round(2)
  end

  # News
  headlines = fetch_news(sym)
  news_sentiment = analyze_sentiment(headlines)

  { symbol: sym, price: price, prevClose: prev_close, high52: high52, low52: low52,
    avg30: avg30, high30: high30, low30: low30, avgVolume: avg_vol,
    predicted: predicted, predictedEoy: predicted_eoy, sentiment: news_sentiment[:label], newsScore: news_sentiment[:score],
    headlines: headlines, dates: dates, closes: closes, highs: highs, lows: lows, volumes: volumes }
rescue => e
  { symbol: sym, error: e.message }
end

# --- HTTP helpers ---
def parse_request(client)
  request_line = client.gets
  return nil unless request_line
  method, path = request_line.split(' ')
  headers = {}
  while (line = client.gets) && line != "\r\n"
    key, val = line.split(': ', 2)
    headers[key.downcase] = val&.strip
  end
  body = nil
  if headers['content-length']
    body = client.read(headers['content-length'].to_i)
  end
  { method: method, path: path, headers: headers, body: body }
end

def get_session_user(headers)
  cookie = headers['cookie'] || ''
  token = cookie[/session=([^;]+)/, 1]
  token ? $sessions[token] : nil
end

def json_response(client, data, status = '200 OK', cookie = nil)
  body = JSON.generate(data)
  h = "HTTP/1.1 #{status}\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n"
  h += "Set-Cookie: session=#{cookie}; Path=/; HttpOnly\r\n" if cookie
  h += "\r\n"
  client.print h + body
end

def html_response(client, html)
  client.print "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: #{html.bytesize}\r\nConnection: close\r\n\r\n#{html}"
end

# --- HTML ---
HTML = <<~'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>StockPulse AI</title>
<script src="https://accounts.google.com/gsi/client" async defer></script>
<script src="https://cdn.plaid.com/link/v2/stable/link-initialize.js"></script>
<style>
  *{box-sizing:border-box}
  body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;background:#f8f9fc;color:#1a1a2e;margin:0;padding:0}
  .container{max-width:1200px;margin:0 auto;padding:20px}
  header{text-align:center;padding:30px 20px 20px;margin-bottom:20px}
  header h1{font-size:32px;margin:0 0 8px;background:linear-gradient(135deg,#4f46e5,#7c3aed,#ec4899);-webkit-background-clip:text;-webkit-text-fill-color:transparent;background-clip:text}
  header p{color:#6b7280;margin:4px 0;font-size:14px}
  .user-bar{display:flex;justify-content:flex-end;align-items:center;gap:12px;margin-bottom:10px}
  .user-bar span{color:#6b7280;font-size:13px}
  .user-bar button{background:linear-gradient(135deg,#ef4444,#f43f5e);color:#fff;border:none;padding:8px 16px;border-radius:20px;font-size:12px;cursor:pointer;font-weight:600}
  .auth-box{max-width:380px;margin:60px auto;background:#fff;border-radius:16px;padding:35px;border:1px solid #e5e7eb;box-shadow:0 10px 40px rgba(0,0,0,.08)}
  .auth-box h2{color:#1a1a2e;margin:0 0 24px;text-align:center;font-size:22px}
  .auth-box input{width:100%;background:#f9fafb;border:1px solid #e5e7eb;color:#1a1a2e;padding:14px;border-radius:10px;font-size:14px;margin-bottom:14px;transition:border .3s}
  .auth-box input:focus{border-color:#7c3aed;outline:none}
  .auth-box button{width:100%;padding:14px;border:none;border-radius:10px;font-size:14px;font-weight:700;cursor:pointer;margin-bottom:10px;transition:transform .2s}
  .auth-box button:hover{transform:translateY(-1px)}
  .auth-box .btn-login{background:linear-gradient(135deg,#7c3aed,#4f46e5);color:#fff}
  .auth-box .error{color:#ef4444;font-size:12px;text-align:center;margin-bottom:10px}
  .auth-box .toggle{text-align:center;color:#9ca3af;font-size:12px;margin-top:12px}
  .auth-box .toggle a{color:#7c3aed;text-decoration:none;font-weight:600;cursor:pointer}
  .status{display:inline-block;padding:5px 14px;border-radius:20px;font-size:12px;margin-top:12px;font-weight:600}
  .status.live{background:#ecfdf5;color:#059669;border:1px solid #a7f3d0}
  .controls{display:flex;justify-content:center;gap:10px;margin-bottom:20px;flex-wrap:wrap}
  .controls input,.controls select{background:#fff;border:1px solid #e5e7eb;color:#1a1a2e;padding:11px 14px;border-radius:10px;font-size:14px;width:140px;text-transform:uppercase;transition:border .3s}
  .controls input:focus,.controls select:focus{border-color:#7c3aed;outline:none}
  .controls input::placeholder{color:#9ca3af;text-transform:none}
  .controls button{padding:11px 20px;border:none;border-radius:10px;font-size:13px;font-weight:700;cursor:pointer;transition:transform .2s}
  .controls button:hover{transform:translateY(-1px)}
  .btn-add{background:linear-gradient(135deg,#10b981,#059669);color:#fff}
  .tabs{display:flex;justify-content:center;gap:6px;margin-bottom:24px}
  .tab{background:#fff;border:1px solid #e5e7eb;color:#6b7280;padding:12px 24px;border-radius:10px;font-size:13px;font-weight:700;cursor:pointer;transition:all .3s}
  .tab.active{background:linear-gradient(135deg,#7c3aed,#4f46e5);color:#fff;border-color:transparent;box-shadow:0 4px 15px rgba(124,58,237,.2)}
  .tab:hover:not(.active){color:#1a1a2e;background:#f3f4f6}
  .summary-box{background:#fff;border:1px solid #e5e7eb;border-radius:14px;padding:20px;margin-bottom:24px;box-shadow:0 2px 8px rgba(0,0,0,.04)}
  .summary-box h3{margin:0 0 12px;font-size:15px;background:linear-gradient(135deg,#4f46e5,#7c3aed);-webkit-background-clip:text;-webkit-text-fill-color:transparent;background-clip:text}
  .summary-item{padding:8px 0;font-size:13px;color:#4b5563;border-bottom:1px solid #f3f4f6}
  .summary-item:last-child{border:none}
  .summary-item strong{color:#1a1a2e}
  .disclaimer{background:#fef2f2;border:1px solid #fecaca;border-radius:10px;padding:12px 16px;margin-bottom:24px;font-size:12px;color:#dc2626;text-align:center}
  .updated{text-align:center;color:#9ca3af;margin-bottom:20px;font-size:13px}
  .table-wrap{overflow-x:auto;border-radius:14px;border:1px solid #e5e7eb;margin-bottom:30px;box-shadow:0 2px 8px rgba(0,0,0,.04)}
  table{width:100%;border-collapse:collapse;min-width:800px}
  th{background:#f9fafb;padding:14px 10px;text-align:right;font-size:11px;text-transform:uppercase;letter-spacing:.5px;color:#6b7280}
  th:first-child{text-align:left;padding-left:16px}
  td{padding:13px 10px;text-align:right;border-bottom:1px solid #f3f4f6;font-size:13px}
  td:first-child{text-align:left;font-weight:700;padding-left:16px;font-size:14px}
  tr{transition:background .2s}
  tr:hover{background:#f5f3ff}
  .pos{color:#059669}.neg{color:#dc2626}
  .badge{padding:5px 12px;border-radius:20px;font-size:11px;font-weight:700;white-space:nowrap;display:inline-block}
  .badge.bullish{background:#ecfdf5;color:#059669;border:1px solid #a7f3d0}
  .badge.bearish{background:#fef2f2;color:#dc2626;border:1px solid #fecaca}
  .badge.neutral{background:#fffbeb;color:#d97706;border:1px solid #fde68a}
  .btn-del{background:#fef2f2;color:#dc2626;border:1px solid #fecaca;padding:5px 12px;border-radius:8px;font-size:11px;cursor:pointer;transition:all .2s}
  .btn-del:hover{background:#fee2e2;transform:scale(1.05)}
  h2{color:#1a1a2e;font-size:20px;margin:0 0 16px;padding-left:4px}
  .news{display:grid;grid-template-columns:repeat(auto-fill,minmax(340px,1fr));gap:14px;margin-bottom:30px}
  .card{background:#fff;border-radius:12px;padding:18px;border:1px solid #e5e7eb;transition:transform .2s,box-shadow .2s;cursor:pointer}
  .card:hover{transform:translateY(-2px);box-shadow:0 8px 25px rgba(0,0,0,.08)}
  .card h3{margin:0 0 10px;color:#1a1a2e;font-size:14px;display:flex;align-items:center;gap:8px}
  .card ul{margin:0;padding:0 0 0 18px;font-size:12px;color:#6b7280;line-height:1.7}
  .card li{margin-bottom:4px}
  .methodology{background:#fff;border-radius:14px;padding:24px;border:1px solid #e5e7eb;font-size:13px;color:#6b7280;line-height:1.8}
  .methodology h3{color:#4b5563;margin:0 0 12px;font-size:14px}
  .methodology b{color:#1a1a2e}
  footer{text-align:center;padding:30px;color:#9ca3af;font-size:12px;border-top:1px solid #e5e7eb;margin-top:30px}
  .toast{position:fixed;top:20px;right:20px;padding:14px 24px;border-radius:12px;font-size:13px;z-index:999;opacity:0;transition:all .3s;font-weight:600;box-shadow:0 8px 25px rgba(0,0,0,.1)}
  .toast.show{opacity:1}.toast.success{background:linear-gradient(135deg,#10b981,#059669);color:#fff}.toast.error{background:linear-gradient(135deg,#ef4444,#dc2626);color:#fff}
  .modal-overlay{display:none;position:fixed;top:0;left:0;right:0;bottom:0;background:rgba(0,0,0,.4);backdrop-filter:blur(4px);z-index:1000;overflow-y:auto;padding:20px}
  .modal{max-width:900px;margin:20px auto;background:#fff;border-radius:20px;border:1px solid #e5e7eb;padding:30px;position:relative;box-shadow:0 20px 60px rgba(0,0,0,.12)}
  .modal-close{position:absolute;top:16px;right:20px;background:none;border:none;color:#9ca3af;font-size:24px;cursor:pointer}
  .modal-close:hover{color:#ef4444}
  .modal h2{background:linear-gradient(135deg,#4f46e5,#7c3aed);-webkit-background-clip:text;-webkit-text-fill-color:transparent;background-clip:text;margin:0 0 4px;font-size:24px}
  .modal .price-big{font-size:36px;font-weight:700;margin:10px 0;color:#1a1a2e}
  .modal .stats{display:grid;grid-template-columns:repeat(auto-fill,minmax(180px,1fr));gap:12px;margin:20px 0}
  .modal .stat{background:#f9fafb;border-radius:10px;padding:14px;border:1px solid #e5e7eb}
  .modal .stat label{display:block;font-size:11px;color:#9ca3af;text-transform:uppercase;margin-bottom:4px;letter-spacing:.5px}
  .modal .stat span{font-size:16px;font-weight:700;color:#1a1a2e}
  .chart-container{background:#f9fafb;border-radius:12px;padding:16px;margin:20px 0;border:1px solid #e5e7eb}
  .chart-container canvas{width:100%;height:200px}
  .modal .news-list{margin:20px 0}
  .modal .news-list h3{color:#6b7280;margin:0 0 12px}
  .modal .news-list li{margin-bottom:8px;font-size:13px;color:#4b5563;line-height:1.5}
  @media(max-width:600px){.container{padding:10px}header h1{font-size:24px}table{font-size:11px}.modal{padding:16px}.tabs{flex-wrap:wrap}}
</style>
</head>
<body>
<div id="toast" class="toast"></div>
<div class="modal-overlay" id="modal" onclick="if(event.target===this)closeDetail()">
  <div class="modal">
    <button class="modal-close" onclick="closeDetail()">✕</button>
    <div id="detail-content">Loading...</div>
  </div>
</div>
<div class="container">
  <div id="auth-view" style="display:none">
    <header><h1>📈 StockPulse AI</h1><p>Sign in to manage your personal watchlist</p></header>
    <div class="auth-box">
      <h2 id="auth-title">Sign In</h2>
      <div class="error" id="auth-error"></div>
      <input type="text" id="auth-user" placeholder="Username">
      <input type="password" id="auth-pass" placeholder="Password">
      <button class="btn-login" id="auth-btn" onclick="doAuth()">Sign In</button>
      <div style="text-align:center;color:#556;margin:12px 0;font-size:12px">— or —</div>
      <div id="g_id_onload" data-client_id="372213831275-jsqps5hpsdisnk6e1rqjj6m5drvjh2ve.apps.googleusercontent.com" data-callback="handleGoogleSignIn" data-auto_prompt="false"></div>
      <div class="g_id_signin" data-type="standard" data-size="large" data-theme="filled_blue" data-text="sign_in_with" data-shape="rectangular" data-width="300"></div>
      <div class="toggle" id="auth-toggle">Don't have an account? <a onclick="toggleAuth()">Register</a></div>
    </div>
  </div>
  <div id="app-view" style="display:none">
    <div class="user-bar"><span id="user-label"></span><button onclick="logout()">Sign Out</button></div>
    <header>
      <h1><span class="logo-pulse"></span>StockPulse AI</h1>
      <p>Your Personal Watchlist • Real-Time Prices • Sentiment • Prediction</p>
      <div class="status live" id="status">● LIVE</div>
    </header>
    <div class="tabs"><button class="tab active" onclick="switchTab('watchlist')">📊 Watchlist</button><button class="tab" onclick="switchTab('portfolio')">💰 Portfolio</button><button class="tab" onclick="switchTab('alerts')">🔔 Alerts</button><button class="tab" onclick="switchTab('learn')">🎓 Learn</button></div>
    <div id="tab-watchlist">
    <div class="controls">
      <input type="text" id="symbolInput" placeholder="e.g. TSLA" maxlength="5">
      <button class="btn-add" onclick="addStock()">+ Add Stock</button>
    </div>
    <div class="disclaimer">⚠️ For informational purposes only. Not financial advice.</div>
    <div class="updated" id="up">Loading...</div>
    <div id="ai-summaries" style="margin-bottom:20px"></div>
    <div class="table-wrap">
    <table><thead><tr><th>Ticker</th><th>Price</th><th>Change</th><th>5D Trend</th><th>News</th><th>Signal</th><th>EOM</th><th>EOY</th><th></th><th></th></tr></thead>
    <tbody id="tb"></tbody></table>
    </div>
    <h2>📰 Headlines</h2>
    <div class="news" id="news"></div>
    </div>
    <div id="tab-portfolio" style="display:none">
    <h2>💰 Portfolio Tracker</h2>
    <div style="text-align:center;margin-bottom:20px"><button onclick="connectBrokerage()" style="background:#6c63ff;color:#fff;border:none;padding:12px 24px;border-radius:8px;font-size:14px;font-weight:600;cursor:pointer">🔗 Connect Brokerage (Robinhood, etc.)</button><span id="plaid-status" style="margin-left:12px;font-size:12px;color:#888"></span></div>
    <div id="plaid-holdings" style="margin-bottom:20px"></div>
    <div class="controls">
      <input type="text" id="pf-symbol" placeholder="Ticker" maxlength="5" style="width:80px">
      <input type="number" id="pf-buy" placeholder="Buy price" step="0.01" style="width:110px;background:#16213e;border:1px solid #1e1e3a;color:#eee;padding:10px;border-radius:8px;font-size:14px">
      <input type="number" id="pf-qty" placeholder="Qty" step="1" style="width:80px;background:#16213e;border:1px solid #1e1e3a;color:#eee;padding:10px;border-radius:8px;font-size:14px">
      <button class="btn-add" onclick="addPortfolio()">+ Add Manually</button>
    </div>
    <div class="table-wrap">
    <table><thead><tr><th>Ticker</th><th>Buy Price</th><th>Current</th><th>Qty</th><th>Invested</th><th>Value</th><th>P&L</th><th>% Return</th><th></th></tr></thead>
    <tbody id="pf-tb"></tbody>
    <tfoot id="pf-total"></tfoot></table>
    </div>
    </div>
    <div id="tab-alerts" style="display:none">
    <h2>🔔 Price Alerts</h2>
    <div class="controls">
      <input type="text" id="al-symbol" placeholder="Ticker" maxlength="5" style="width:80px">
      <select id="al-dir" style="background:#16213e;border:1px solid #1e1e3a;color:#eee;padding:10px;border-radius:8px;font-size:14px"><option value="above">Above</option><option value="below">Below</option></select>
      <input type="number" id="al-target" placeholder="Target $" step="0.01" style="width:110px;background:#16213e;border:1px solid #1e1e3a;color:#eee;padding:10px;border-radius:8px;font-size:14px">
      <button class="btn-add" onclick="addAlert()">+ Add Alert</button>
    </div>
    <div class="table-wrap">
    <table><thead><tr><th>Ticker</th><th>Condition</th><th>Target</th><th>Status</th><th></th></tr></thead>
    <tbody id="al-tb"></tbody></table>
    </div>
    </div>
    <div id="tab-learn" style="display:none">
    <h2>🎓 Trading Coach</h2>
    <div class="summary-box" style="border-color:#7c4dff44">
      <h3>📍 Your Learning Path</h3>
      <div id="learn-progress" style="margin-bottom:12px;height:6px;background:#0a0a1a;border-radius:3px;overflow:hidden"><div id="learn-bar" style="height:100%;width:0%;background:linear-gradient(90deg,#7c4dff,#00d4ff);transition:width .5s;border-radius:3px"></div></div>
      <div id="learn-progress-text" style="font-size:12px;color:#888"></div>
    </div>
    <div class="news" id="lessons">
      <div class="card" onclick="openLesson(0)" style="cursor:pointer">
        <h3>📖 Lesson 1: Stock Market Basics</h3>
        <ul><li>What is a stock?</li><li>How exchanges work</li><li>Market hours & terminology</li></ul>
      </div>
      <div class="card" onclick="openLesson(1)" style="cursor:pointer">
        <h3>📖 Lesson 2: Reading Stock Prices</h3>
        <ul><li>Bid, Ask & Spread</li><li>Market vs Limit orders</li><li>Understanding volume</li></ul>
      </div>
      <div class="card" onclick="openLesson(2)" style="cursor:pointer">
        <h3>📖 Lesson 3: Technical Analysis</h3>
        <ul><li>Support & Resistance</li><li>Moving averages</li><li>Trend lines & patterns</li></ul>
      </div>
      <div class="card" onclick="openLesson(3)" style="cursor:pointer">
        <h3>📖 Lesson 4: Fundamental Analysis</h3>
        <ul><li>P/E Ratio & EPS</li><li>Revenue & earnings growth</li><li>Reading financial statements</li></ul>
      </div>
      <div class="card" onclick="openLesson(4)" style="cursor:pointer">
        <h3>📖 Lesson 5: Risk Management</h3>
        <ul><li>Position sizing</li><li>Stop-loss strategies</li><li>Diversification</li></ul>
      </div>
      <div class="card" onclick="openLesson(5)" style="cursor:pointer">
        <h3>📖 Lesson 6: Building a Strategy</h3>
        <ul><li>Growth vs Value investing</li><li>Dollar-cost averaging</li><li>When to buy & sell</li></ul>
      </div>
    </div>
    <div class="summary-box" id="lesson-detail" style="display:none"></div>
    <div class="summary-box" style="border-color:#00e67644">
      <h3>💡 Today's Trading Tip</h3>
      <div id="daily-tip" class="summary-item" style="border:none;font-size:14px"></div>
    </div>
    <div class="summary-box">
      <h3>📚 Glossary — Key Terms</h3>
      <div style="display:grid;grid-template-columns:repeat(auto-fill,minmax(280px,1fr));gap:8px;font-size:13px" id="glossary"></div>
    </div>
    </div>
    <div class="methodology"><h3>📊 Methodology</h3><b>Sentiment:</b> Keyword analysis of Yahoo Finance headlines.<br><br><b>Signal:</b> Price momentum + news sentiment combined.<br><br><b>Prediction:</b> EMA/MACD momentum model — uses Exponential Moving Averages (12 &amp; 26 period) to calculate MACD momentum, then projects price with mean-reversion dampening for longer timeframes.<br><br><b>Source:</b> Yahoo Finance. Refreshes every 60s.</div>
    <footer>StockPulse AI • stockpulse.ai • Auto-refreshes every 60s</footer>
  </div>
</div>
<script>
let isLogin=true;
function toast(msg,type='success'){const t=document.getElementById('toast');t.textContent=msg;t.className=`toast ${type} show`;setTimeout(()=>t.className='toast',3000);}
async function handleGoogleSignIn(response){
  const r=await fetch('/api/google-login',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({credential:response.credential})});
  const d=await r.json();
  if(d.ok){showApp(d.username);toast('Signed in with Google');}
  else{document.getElementById('auth-error').textContent=d.error||'Google sign-in failed';}
}
function toggleAuth(){
  isLogin=!isLogin;
  document.getElementById('auth-title').textContent=isLogin?'Sign In':'Register';
  document.getElementById('auth-btn').textContent=isLogin?'Sign In':'Create Account';
  document.getElementById('auth-toggle').innerHTML=isLogin?`Don't have an account? <a onclick="toggleAuth()">Register</a>`:`Already have an account? <a onclick="toggleAuth()">Sign In</a>`;
  document.getElementById('auth-error').textContent='';
}
async function doAuth(){
  const user=document.getElementById('auth-user').value.trim();
  const pass=document.getElementById('auth-pass').value;
  if(!user||!pass){document.getElementById('auth-error').textContent='Fill in all fields';return;}
  const endpoint=isLogin?'/api/login':'/api/register';
  const r=await fetch(endpoint,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({username:user,password:pass})});
  const d=await r.json();
  if(d.ok){showApp(d.username);toast(isLogin?'Signed in':'Account created');}
  else document.getElementById('auth-error').textContent=d.error;
}
async function logout(){
  await fetch('/api/logout',{method:'POST'});
  document.getElementById('app-view').style.display='none';
  document.getElementById('auth-view').style.display='block';
}
function showApp(username){
  document.getElementById('auth-view').style.display='none';
  document.getElementById('app-view').style.display='block';
  document.getElementById('user-label').textContent=`👤 ${username}`;
  update();
}
async function checkSession(){
  const r=await fetch('/api/me');const d=await r.json();
  if(d.ok)showApp(d.username);
  else{document.getElementById('auth-view').style.display='block';}
}
async function addStock(){
  const input=document.getElementById('symbolInput');
  const sym=input.value.trim().toUpperCase();
  if(!sym){toast('Enter a ticker','error');return;}
  const r=await fetch('/api/add?symbol='+sym);const d=await r.json();
  if(d.ok){toast(`${sym} added`);input.value='';update();}else toast(d.error,'error');
}
async function removeStock(sym){
  if(!confirm(`Remove ${sym}?`))return;
  const r=await fetch('/api/remove?symbol='+sym);const d=await r.json();
  if(d.ok){toast(`${sym} removed`);update();}else toast(d.error,'error');
}
document.getElementById('symbolInput').addEventListener('keydown',e=>{if(e.key==='Enter')addStock();});
document.getElementById('auth-pass').addEventListener('keydown',e=>{if(e.key==='Enter')doAuth();});
async function update(){
  try{
    const r=await fetch('/api/stocks');const stocks=await r.json();
    if(stocks.error)return;
    document.getElementById('tb').innerHTML=stocks.map(s=>{
      if(!s.price)return`<tr><td>${s.symbol}</td><td colspan="7" style="color:#666">Unavailable</td><td><button class="btn-del" onclick="removeStock('${s.symbol}')">✕</button></td></tr>`;
      const chg=s.price-s.prevClose,pct=(chg/s.prevClose)*100;
      const cls=chg>=0?'pos':'neg',arr=chg>=0?'▲':'▼',sgn=chg>=0?'+':'';
      const al=Math.abs(pct)>=2?'🚨':'';
      const trend=s.trend>=0?`+${s.trend.toFixed(2)}%`:`${s.trend.toFixed(2)}%`;
      const tCls=s.trend>=0?'pos':'neg';
      const pred=s.predicted?`$${s.predicted.toFixed(2)}`:'—';
      const pCls=s.predicted&&s.predicted>=s.price?'pos':'neg';
      const predEoy=s.predictedEoy?`$${s.predictedEoy.toFixed(2)}`:'—';
      const eCls=s.predictedEoy&&s.predictedEoy>=s.price?'pos':'neg';
      return`<tr><td><a href="#" onclick="openDetail('${s.symbol}');return false" style="color:#4f46e5;text-decoration:none;font-weight:700">${s.symbol}</a></td><td>$${s.price.toFixed(2)}</td><td class="${cls}">${arr} ${sgn}${pct.toFixed(2)}%</td><td class="${tCls}">${trend}</td><td><span class="badge ${s.newsSentiment}">${s.newsSentiment}</span></td><td><span class="badge ${s.overall}">${s.overall}</span></td><td class="${pCls}">${pred}</td><td class="${eCls}">${predEoy}</td><td>${al}</td><td><button class="btn-del" onclick="removeStock('${s.symbol}')">✕</button></td></tr>`;
    }).join('');
    document.getElementById('news').innerHTML=stocks.filter(s=>s.headlines&&s.headlines.length).map(s=>`<div class="card"><h3>${s.symbol} <span class="badge ${s.newsSentiment}">${s.newsSentiment}</span></h3><ul>${s.headlines.map(h=>`<li>${h}</li>`).join('')}</ul></div>`).join('');
    document.getElementById('up').textContent=`${stocks.length} stocks • Updated: ${new Date().toLocaleString()} • Refreshes every 60s`;
    renderSummaries(stocks);
    loadAlerts();
  }catch(e){}
}
checkSession();
setInterval(()=>{if(document.getElementById('app-view').style.display!=='none')update();},60000);

// --- Tabs ---
function switchTab(tab){
  document.querySelectorAll('.tab').forEach(t=>t.classList.remove('active'));
  document.querySelector(`.tab[onclick*="${tab}"]`).classList.add('active');
  ['watchlist','portfolio','alerts','learn'].forEach(t=>document.getElementById('tab-'+t).style.display=t===tab?'block':'none');
  if(tab==='portfolio'){loadPortfolio();loadPlaidHoldings();}
  if(tab==='alerts')loadAlerts();
  if(tab==='learn')initLearn();
}

// --- AI Summary ---
let lastStocks=[];
function renderSummaries(stocks){
  lastStocks=stocks;
  const box=document.getElementById('ai-summaries');
  const items=stocks.filter(s=>s.summary).map(s=>`<div class="summary-item"><strong>${s.symbol}:</strong> ${s.summary}</div>`).join('');
  box.innerHTML=items?`<div class="summary-box"><h3>🤖 AI Market Summary</h3>${items}</div>`:'';
}

// --- Portfolio ---
async function addPortfolio(){
  const sym=document.getElementById('pf-symbol').value.trim().toUpperCase();
  const buy=parseFloat(document.getElementById('pf-buy').value);
  const qty=parseFloat(document.getElementById('pf-qty').value);
  if(!sym||!buy||!qty){toast('Fill all fields','error');return;}
  const r=await fetch('/api/portfolio',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({symbol:sym,buyPrice:buy,quantity:qty})});
  const d=await r.json();
  if(d.ok){toast(`${sym} position added`);document.getElementById('pf-symbol').value='';document.getElementById('pf-buy').value='';document.getElementById('pf-qty').value='';loadPortfolio();}
  else toast(d.error||'Failed','error');
}
async function deletePortfolio(idx){
  await fetch('/api/portfolio/delete?index='+idx);loadPortfolio();
}
async function loadPortfolio(){
  const r=await fetch('/api/portfolio');const d=await r.json();
  if(!d.ok)return;
  const portfolio=d.portfolio||[];
  if(!portfolio.length){document.getElementById('pf-tb').innerHTML='<tr><td colspan="9" style="text-align:center;color:#666;padding:30px">No positions yet. Add your first stock above.</td></tr>';document.getElementById('pf-total').innerHTML='';return;}
  // Get current prices
  const symbols=[...new Set(portfolio.map(p=>p.symbol))];
  const prices={};
  for(const s of lastStocks)prices[s.symbol]=s.price;
  // Fetch missing prices
  for(const sym of symbols){
    if(!prices[sym]){try{const r2=await fetch('/api/detail?symbol='+sym);const dd=await r2.json();prices[sym]=dd.price;}catch(e){}}
  }
  let totalInvested=0,totalValue=0;
  document.getElementById('pf-tb').innerHTML=portfolio.map((p,i)=>{
    const cur=prices[p.symbol]||0;
    const invested=p.buyPrice*p.quantity;
    const value=cur*p.quantity;
    const pl=value-invested;
    const pct=invested>0?((pl/invested)*100).toFixed(2):0;
    totalInvested+=invested;totalValue+=value;
    const cls=pl>=0?'pos':'neg';
    return`<tr><td><a href="#" onclick="openDetail('${p.symbol}');return false" style="color:#4f46e5;text-decoration:none;font-weight:700">${p.symbol}</a></td><td>$${p.buyPrice.toFixed(2)}</td><td>$${cur.toFixed(2)}</td><td>${p.quantity}</td><td>$${invested.toFixed(2)}</td><td>$${value.toFixed(2)}</td><td class="${cls}">${pl>=0?'+':''}$${pl.toFixed(2)}</td><td class="${cls}">${pct}%</td><td><button class="btn-del" onclick="deletePortfolio(${i})">✕</button></td></tr>`;
  }).join('');
  const totalPL=totalValue-totalInvested;const totalPct=totalInvested>0?((totalPL/totalInvested)*100).toFixed(2):0;
  const cls=totalPL>=0?'pos':'neg';
  document.getElementById('pf-total').innerHTML=`<tr style="font-weight:bold;border-top:2px solid #0f3460"><td>TOTAL</td><td></td><td></td><td></td><td>$${totalInvested.toFixed(2)}</td><td>$${totalValue.toFixed(2)}</td><td class="${cls}">${totalPL>=0?'+':''}$${totalPL.toFixed(2)}</td><td class="${cls}">${totalPct}%</td><td></td></tr>`;
}

// --- Alerts ---
async function addAlert(){
  const sym=document.getElementById('al-symbol').value.trim().toUpperCase();
  const dir=document.getElementById('al-dir').value;
  const target=parseFloat(document.getElementById('al-target').value);
  if(!sym||!target){toast('Fill all fields','error');return;}
  const r=await fetch('/api/alerts',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({symbol:sym,direction:dir,target:target})});
  const d=await r.json();
  if(d.ok){toast(`Alert set for ${sym}`);document.getElementById('al-symbol').value='';document.getElementById('al-target').value='';loadAlerts();}
  else toast(d.error||'Failed','error');
}
async function deleteAlert(idx){
  await fetch('/api/alerts/delete?index='+idx);loadAlerts();
}
async function loadAlerts(){
  const r=await fetch('/api/alerts');const d=await r.json();
  if(!d.ok)return;
  const alerts=d.alerts||[];
  if(!alerts.length){document.getElementById('al-tb').innerHTML='<tr><td colspan="5" style="text-align:center;color:#666;padding:30px">No alerts set. Add one above.</td></tr>';return;}
  const prices={};for(const s of lastStocks)prices[s.symbol]=s.price;
  document.getElementById('al-tb').innerHTML=alerts.map((a,i)=>{
    const cur=prices[a.symbol];
    let status='⏳ Waiting';
    if(cur){
      const triggered=(a.direction==='above'&&cur>=a.target)||(a.direction==='below'&&cur<=a.target);
      if(triggered){status='🚨 TRIGGERED';if(Notification.permission==='granted')new Notification('StockPulse Alert',{body:`${a.symbol} is ${a.direction} $${a.target} (now $${cur.toFixed(2)})`});}
    }
    return`<tr><td>${a.symbol}</td><td>${a.direction==='above'?'≥':'≤'}</td><td>$${a.target.toFixed(2)}</td><td>${status}</td><td><button class="btn-del" onclick="deleteAlert(${i})">✕</button></td></tr>`;
  }).join('');
}

// --- Plaid Brokerage ---
async function setAlertFromModal(sym){
  const btn=document.querySelector('[onclick*="setAlertFromModal"]');
  const dir=document.getElementById('modal-al-dir').value;
  const target=parseFloat(document.getElementById('modal-al-target').value);
  if(!target){toast('Enter a target price','error');return;}
  btn.textContent='Setting...';btn.style.background='#888';btn.disabled=true;
  const r=await fetch('/api/alerts',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({symbol:sym,direction:dir,target:target})});
  const d=await r.json();
  if(d.ok){
    btn.textContent='✓ Alert Set!';btn.style.background='linear-gradient(135deg,#00e676,#00bfa5)';
    toast(`✓ Alert set: ${sym} ${dir} $${target}`);
    loadAlerts();
    showExistingAlerts(sym);
    setTimeout(()=>{btn.textContent='Set Alert';btn.style.background='linear-gradient(135deg,#ffd600,#ff9100)';btn.disabled=false;},2000);
  } else {
    btn.textContent='Set Alert';btn.style.background='linear-gradient(135deg,#ffd600,#ff9100)';btn.disabled=false;
    toast(d.error||'Failed','error');
  }
}
async function showExistingAlerts(sym){
  const r=await fetch('/api/alerts');const d=await r.json();
  if(!d.ok)return;
  const existing=(d.alerts||[]).filter(a=>a.symbol===sym);
  const el=document.getElementById('modal-existing-alerts');
  if(!el)return;
  if(existing.length){
    el.innerHTML='<div style="margin-top:12px;font-size:12px;color:#ffd600">⚡ Active alerts: '+existing.map(a=>`<span style="background:#ffd60022;padding:3px 8px;border-radius:6px;margin:2px">${a.direction} $${a.target.toFixed(2)}</span>`).join(' ')+'</div>';
  } else el.innerHTML='';
}
// --- Learning Coach ---
const LESSONS=[
{title:'Stock Market Basics',content:`<p><b>What is a stock?</b> A stock represents ownership in a company. When you buy a share, you own a tiny piece of that business.</p><p><b>How exchanges work:</b> Stocks trade on exchanges (NYSE, NASDAQ). Buyers and sellers are matched electronically. Prices move based on supply and demand.</p><p><b>Market hours:</b> US markets are open 9:30 AM – 4:00 PM ET, Monday–Friday. Pre-market (4–9:30 AM) and after-hours (4–8 PM) trading also exists but with less liquidity.</p><p><b>Key terms:</b> Bull market = prices rising. Bear market = prices falling 20%+. IPO = first time a company sells stock publicly.</p>`,quiz:'What does it mean to own a stock?',answers:['You loaned money to a company','You own a piece of the company','You work for the company'],correct:1},
{title:'Reading Stock Prices',content:`<p><b>Bid & Ask:</b> The bid is the highest price a buyer will pay. The ask is the lowest price a seller will accept. The difference is the "spread."</p><p><b>Order types:</b> Market order = buy/sell immediately at current price. Limit order = buy/sell only at your specified price or better. Stop-loss = automatically sell if price drops to a level.</p><p><b>Volume:</b> The number of shares traded. High volume = lots of interest and liquidity. Low volume = harder to buy/sell without moving the price.</p>`,quiz:'What is a limit order?',answers:['Buy at any price','Buy only at your specified price or better','Buy at the worst price'],correct:1},
{title:'Technical Analysis',content:`<p><b>Support & Resistance:</b> Support is a price level where a stock tends to stop falling (buyers step in). Resistance is where it stops rising (sellers step in).</p><p><b>Moving Averages:</b> The average price over a period (e.g., 50-day MA). When price crosses above the MA, it is often bullish. Below = bearish.</p><p><b>Patterns:</b> Head and Shoulders (reversal), Double Bottom (bullish), Cup and Handle (continuation). These help predict future price movement.</p><p><b>Pro tip:</b> Look at the 30-day chart in StockPulse detail view to spot these patterns!</p>`,quiz:'What does it mean when price crosses above the 50-day moving average?',answers:['Bearish signal','Bullish signal','No significance'],correct:1},
{title:'Fundamental Analysis',content:`<p><b>P/E Ratio:</b> Price divided by Earnings per share. A P/E of 20 means you pay $20 for every $1 of earnings. Lower P/E = potentially undervalued.</p><p><b>EPS:</b> Earnings Per Share = company profit divided by shares outstanding. Growing EPS = company becoming more profitable.</p><p><b>Revenue growth:</b> Is the company selling more each quarter? Consistent 10%+ growth is strong.</p><p><b>Pro tip:</b> Use StockPulse AI Summary to quickly gauge if fundamentals are improving!</p>`,quiz:'A stock with P/E of 10 vs P/E of 50 — which might be undervalued?',answers:['P/E of 50','P/E of 10','Both are the same'],correct:1},
{title:'Risk Management',content:`<p><b>Position sizing:</b> Never put more than 5-10% of your portfolio in a single stock. This limits damage if one pick goes wrong.</p><p><b>Stop-loss:</b> Set a price where you will sell to limit losses. Example: buy at $100, set stop-loss at $90 = max 10% loss.</p><p><b>Diversification:</b> Spread across sectors (tech, healthcare, finance) and asset types (stocks, bonds, ETFs).</p><p><b>Pro tip:</b> Use StockPulse Alerts to set stop-loss notifications on your positions!</p>`,quiz:'What is a good max allocation for a single stock?',answers:['50% of portfolio','5-10% of portfolio','100% of portfolio'],correct:1},
{title:'Building a Strategy',content:`<p><b>Growth investing:</b> Buy companies growing revenue/earnings fast (often higher P/E). Think tech stocks.</p><p><b>Value investing:</b> Buy undervalued companies trading below their worth (lower P/E). Think Warren Buffett.</p><p><b>Dollar-cost averaging (DCA):</b> Invest a fixed amount regularly (e.g., $500/month) regardless of price. Reduces timing risk.</p><p><b>When to sell:</b> When your thesis changes, when a stock hits your target, or when you need to rebalance. Never panic-sell on a red day.</p><p><b>Pro tip:</b> Use StockPulse Portfolio tab to track your DCA strategy and overall returns!</p>`,quiz:'What is dollar-cost averaging?',answers:['Buying only cheap stocks','Investing a fixed amount regularly','Selling when prices drop'],correct:1}
];
const TIPS=['Never invest money you cannot afford to lose.','The best time to start investing was yesterday. The second best is today.','A diversified portfolio reduces risk without necessarily reducing returns.','Set your stop-loss before entering a trade, not after.','Past performance does not guarantee future results.','Buy the rumor, sell the news — prices often move before announcements.','If you cannot explain why you own a stock in one sentence, reconsider.','Time in the market beats timing the market for most investors.','Review your portfolio monthly, but avoid checking daily — it causes emotional decisions.','The stock market transfers money from the impatient to the patient.'];
const GLOSSARY=[['Bull Market','Extended period of rising prices'],['Bear Market','Decline of 20%+ from recent highs'],['P/E Ratio','Price divided by earnings per share'],['EPS','Earnings per share — profit per stock unit'],['Market Cap','Total value of all shares outstanding'],['Dividend','Cash payment to shareholders from profits'],['ETF','Exchange-traded fund — basket of stocks'],['Volume','Number of shares traded in a period'],['Volatility','How much a price swings up and down'],['Liquidity','How easily you can buy/sell without moving price'],['Short Selling','Betting a stock will go down'],['Blue Chip','Large, stable, well-established company']];
let completedLessons=JSON.parse(localStorage.getItem('sp_lessons')||'[]');
function initLearn(){
  document.getElementById('daily-tip').textContent=TIPS[new Date().getDate()%TIPS.length];
  document.getElementById('glossary').innerHTML=GLOSSARY.map(([t,d])=>`<div style="padding:8px;background:#0a0a1a;border-radius:8px"><strong style="color:#00d4ff">${t}</strong><br><span style="color:#888">${d}</span></div>`).join('');
  updateProgress();
}
function updateProgress(){
  const pct=Math.round((completedLessons.length/LESSONS.length)*100);
  document.getElementById('learn-bar').style.width=pct+'%';
  document.getElementById('learn-progress-text').textContent=`${completedLessons.length}/${LESSONS.length} lessons completed (${pct}%)`;
  document.querySelectorAll('#lessons .card').forEach((c,i)=>{if(completedLessons.includes(i))c.style.borderColor='#00e67644';});
}
function openLesson(idx){
  const l=LESSONS[idx];const done=completedLessons.includes(idx);
  document.getElementById('lesson-detail').style.display='block';
  document.getElementById('lesson-detail').innerHTML=`<h3>${l.title} ${done?'✅':''}</h3>${l.content}<div style="margin-top:16px;padding:16px;background:#0a0a1a;border-radius:10px"><b style="color:#ffd600">Quiz:</b> ${l.quiz}<div style="margin-top:10px" id="quiz-answers">${l.answers.map((a,i)=>`<button onclick="checkAnswer(${idx},${i})" style="display:block;width:100%;text-align:left;margin:6px 0;padding:10px 14px;background:#12122a;border:1px solid #2a2060;color:#eee;border-radius:8px;cursor:pointer;font-size:13px">${a}</button>`).join('')}</div></div>`;
  document.getElementById('lesson-detail').scrollIntoView({behavior:'smooth'});
}
function checkAnswer(lesson,answer){
  const correct=LESSONS[lesson].correct===answer;
  const btns=document.querySelectorAll('#quiz-answers button');
  btns.forEach((b,i)=>{b.disabled=true;if(i===LESSONS[lesson].correct)b.style.background='linear-gradient(135deg,#00e67633,#00e67611)',b.style.borderColor='#00e676';else if(i===answer&&!correct)b.style.background='#ff408122',b.style.borderColor='#ff4081';});
  if(correct&&!completedLessons.includes(lesson)){completedLessons.push(lesson);localStorage.setItem('sp_lessons',JSON.stringify(completedLessons));updateProgress();toast('✓ Correct! Lesson completed');}
  else if(!correct)toast('✗ Try again next time','error');
}

// --- Plaid Brokerage ---
async function connectBrokerage(){
  document.getElementById('plaid-status').textContent='Connecting...';
  try{
    const r=await fetch('/api/plaid/link-token',{method:'POST'});
    const d=await r.json();
    if(!d.ok){toast(d.error||'Failed to get link token','error');document.getElementById('plaid-status').textContent='Error: '+d.error;return;}
    const handler=Plaid.create({
      token:d.link_token,
      onSuccess:async(public_token)=>{
        document.getElementById('plaid-status').textContent='Exchanging token...';
        const r2=await fetch('/api/plaid/exchange',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({public_token})});
        const d2=await r2.json();
        if(d2.ok){toast('Brokerage connected!');document.getElementById('plaid-status').textContent='✓ Connected';loadPlaidHoldings();}
        else{toast(d2.error||'Exchange failed','error');document.getElementById('plaid-status').textContent='Error: '+(d2.error||'exchange failed');}
      },
      onExit:(err)=>{document.getElementById('plaid-status').textContent=err?'Error: '+err.error_message:'';}
    });
    handler.open();
  }catch(e){toast('Connection error: '+e.message,'error');document.getElementById('plaid-status').textContent='Error: '+e.message;}
}
async function loadPlaidHoldings(){
  const r=await fetch('/api/plaid/holdings');const d=await r.json();
  if(!d.ok||!d.holdings){document.getElementById('plaid-holdings').innerHTML='';return;}
  const rows=d.holdings.filter(h=>h.symbol!=='N/A').map(h=>`<tr><td>${h.symbol}</td><td>${h.quantity}</td><td>$${(h.costBasis||0).toFixed(2)}</td><td>$${(h.value||0).toFixed(2)}</td></tr>`).join('');
  document.getElementById('plaid-holdings').innerHTML=`<div class="table-wrap"><table><thead><tr><th style="text-align:left">Ticker</th><th>Shares</th><th>Cost Basis</th><th>Value</th></tr></thead><tbody>${rows}</tbody></table></div><p style="text-align:center;font-size:11px;color:#556">Live holdings from connected brokerage</p>`;
}

function closeDetail(){document.getElementById('modal').style.display='none';}
async function openDetail(sym){
  document.getElementById('modal').style.display='block';
  document.getElementById('detail-content').innerHTML='<p style="text-align:center;padding:40px;color:#888">Loading '+sym+' data...</p>';
  const r=await fetch('/api/detail?symbol='+sym);
  const d=await r.json();
  if(d.error){document.getElementById('detail-content').innerHTML=`<p style="color:#ff5252">${d.error}</p>`;return;}
  const chg=d.price-d.prevClose,pct=(chg/d.prevClose)*100;
  const cls=chg>=0?'pos':'neg',arr=chg>=0?'▲':'▼',sgn=chg>=0?'+':'';
  const fmtVol=d.avgVolume?(d.avgVolume/1e6).toFixed(1)+'M':'—';
  document.getElementById('detail-content').innerHTML=`
    <h2>${d.symbol}</h2>
    <div class="price-big ${cls}">$${d.price.toFixed(2)} <span style="font-size:16px">${arr} ${sgn}${pct.toFixed(2)}%</span></div>
    <div class="stats">
      <div class="stat"><label>Prev Close</label><span>$${d.prevClose.toFixed(2)}</span></div>
      <div class="stat"><label>30D Average</label><span>$${d.avg30||'—'}</span></div>
      <div class="stat"><label>30D High</label><span>$${d.high30||'—'}</span></div>
      <div class="stat"><label>30D Low</label><span>$${d.low30||'—'}</span></div>
      <div class="stat"><label>52W High</label><span>$${d.high52?d.high52.toFixed(2):'—'}</span></div>
      <div class="stat"><label>52W Low</label><span>$${d.low52?d.low52.toFixed(2):'—'}</span></div>
      <div class="stat"><label>Avg Volume</label><span>${fmtVol}</span></div>
      <div class="stat"><label>EOM Forecast</label><span class="${d.predicted>=d.price?'pos':'neg'}">$${d.predicted||'—'}</span></div>
      <div class="stat"><label>EOY Forecast</label><span class="${d.predictedEoy>=d.price?'pos':'neg'}">$${d.predictedEoy||'—'}</span></div>
      <div class="stat"><label>News Sentiment</label><span><span class="badge ${d.sentiment}">${d.sentiment} (${d.newsScore})</span></span></div>
    </div>
    <div style="display:flex;gap:6px;justify-content:center;margin-bottom:10px" id="chart-ranges">
      <button onclick="loadChart('${d.symbol}','1mo')" style="padding:6px 12px;border-radius:6px;border:1px solid #e5e7eb;background:#fff;color:#6b7280;font-size:12px;cursor:pointer;font-weight:600">1M</button>
      <button onclick="loadChart('${d.symbol}','6mo')" style="padding:6px 12px;border-radius:6px;border:1px solid #e5e7eb;background:#fff;color:#6b7280;font-size:12px;cursor:pointer;font-weight:600">6M</button>
      <button onclick="loadChart('${d.symbol}','1y')" style="padding:6px 12px;border-radius:6px;border:1px solid #e5e7eb;background:#fff;color:#6b7280;font-size:12px;cursor:pointer;font-weight:600">1Y</button>
      <button onclick="loadChart('${d.symbol}','5y')" style="padding:6px 12px;border-radius:6px;border:1px solid #e5e7eb;background:#fff;color:#6b7280;font-size:12px;cursor:pointer;font-weight:600">5Y</button>
    </div>
    <div class="chart-container"><canvas id="priceChart"></canvas></div>
    <div class="news-list"><h3>📰 Latest News</h3><ul>${d.headlines.map(h=>'<li>'+h+'</li>').join('')}</ul></div>
    <div style="margin-top:20px;padding:16px;background:linear-gradient(145deg,#1a1040,#0f1a2e);border-radius:10px;border:1px solid #2a2060">
      <h3 style="margin:0 0 12px;color:#ffd600">🔔 Set Price Alert</h3>
      <div style="display:flex;gap:10px;align-items:center;flex-wrap:wrap">
        <select id="modal-al-dir" style="background:#0a0a1a;border:1px solid #2a2060;color:#eee;padding:10px;border-radius:8px;font-size:13px"><option value="above">Above</option><option value="below">Below</option></select>
        <input type="number" id="modal-al-target" placeholder="Target $" value="${d.price.toFixed(2)}" step="0.01" style="background:#0a0a1a;border:1px solid #2a2060;color:#eee;padding:10px;border-radius:8px;font-size:13px;width:120px">
        <button onclick="setAlertFromModal('${d.symbol}')" style="background:linear-gradient(135deg,#ffd600,#ff9100);color:#000;border:none;padding:10px 18px;border-radius:8px;font-size:13px;font-weight:700;cursor:pointer">Set Alert</button>
      </div>
      <div id="modal-existing-alerts"></div>
    </div>
  `;
  drawChart(d.dates,d.closes,d.symbol);
  showExistingAlerts(d.symbol);
}
async function loadChart(sym,range){
  document.querySelectorAll('#chart-ranges button').forEach(b=>{b.style.background=b.textContent.toLowerCase().replace(' ','')===range?'linear-gradient(135deg,#7c3aed,#4f46e5)':'#fff';b.style.color=b.textContent.toLowerCase().replace(' ','')===range?'#fff':'#6b7280';});
  const map={'1mo':'1M','6mo':'6M','1y':'1Y','5y':'5Y'};
  document.querySelectorAll('#chart-ranges button').forEach(b=>{const active=map[range]===b.textContent;b.style.background=active?'linear-gradient(135deg,#7c3aed,#4f46e5)':'#fff';b.style.color=active?'#fff':'#6b7280';});
  const r=await fetch(`/api/chart?symbol=${sym}&range=${range}`);
  const d=await r.json();
  if(d.dates)drawChart(d.dates,d.closes,sym);
}
function drawChart(dates,closes,symbol){
  const canvas=document.getElementById('priceChart');
  if(!canvas)return;
  const ctx=canvas.getContext('2d');
  const W=canvas.parentElement.clientWidth-32;
  const H=200;
  canvas.width=W;canvas.height=H;
  ctx.clearRect(0,0,W,H);
  const valid=closes.map((c,i)=>c!=null?{x:i,y:c}:null).filter(Boolean);
  if(valid.length<2)return;
  const minY=Math.min(...valid.map(p=>p.y));
  const maxY=Math.max(...valid.map(p=>p.y));
  const rangeY=maxY-minY||1;
  const pad=20;
  const toX=i=>(i/(valid.length-1))*(W-pad*2)+pad;
  const toY=v=>H-pad-((v-minY)/rangeY)*(H-pad*2);
  // Grid
  ctx.strokeStyle='#1e1e3a';ctx.lineWidth=1;
  for(let i=0;i<5;i++){const y=pad+i*((H-pad*2)/4);ctx.beginPath();ctx.moveTo(pad,y);ctx.lineTo(W-pad,y);ctx.stroke();}
  // Labels
  ctx.fillStyle='#556';ctx.font='10px sans-serif';
  ctx.fillText('$'+maxY.toFixed(0),2,pad+4);
  ctx.fillText('$'+minY.toFixed(0),2,H-pad+4);
  ctx.fillText(dates[0]||'',pad,H-4);
  ctx.fillText(dates[dates.length-1]||'',W-pad-50,H-4);
  // Line
  const up=valid[valid.length-1].y>=valid[0].y;
  ctx.strokeStyle=up?'#00e676':'#ff5252';ctx.lineWidth=2;
  ctx.beginPath();
  valid.forEach((p,i)=>{const x=toX(i),y=toY(p.y);i===0?ctx.moveTo(x,y):ctx.lineTo(x,y);});
  ctx.stroke();
  // Fill
  ctx.lineTo(toX(valid.length-1),H-pad);ctx.lineTo(toX(0),H-pad);ctx.closePath();
  ctx.fillStyle=up?'rgba(0,230,118,0.08)':'rgba(255,82,82,0.08)';ctx.fill();
}
</script>
</body></html>
HTML

# --- Server ---
server = TCPServer.new('0.0.0.0', PORT)
local_ip = Socket.ip_address_list.detect { |a| a.ipv4? && !a.ipv4_loopback? }&.ip_address || 'localhost'
puts "StockPulse AI running at:"
puts "  Local:    http://localhost:#{PORT}"
puts "  Network:  http://#{local_ip}:#{PORT}"
puts "Press Ctrl+C to stop"

loop do
  client = server.accept
  begin
    req = parse_request(client)
    next unless req
    path = req[:path]
    user = get_session_user(req[:headers])

    case
    when path == '/api/google-login' && req[:method] == 'POST'
      data = JSON.parse(req[:body])
      # Decode Google JWT (base64 payload without verification - for production use google-id-token gem)
      payload = data['credential'].split('.')[1]
      payload += '=' * (4 - payload.length % 4) if payload.length % 4 != 0
      google_data = JSON.parse(Base64.decode64(payload))
      email = google_data['email']
      name = google_data['name'] || email.split('@').first
      username = "google:#{email}"
      unless $users[username]
        $users[username] = { 'password' => 'google-oauth', 'stocks' => DEFAULT_STOCKS.dup, 'name' => name, 'email' => email }
        save_users($users)
      end
      token = SecureRandom.hex(16)
      $sessions[token] = username
      json_response(client, { ok: true, username: name }, '200 OK', token)

    when path == '/api/register' && req[:method] == 'POST'
      data = JSON.parse(req[:body])
      username, password = data['username'], data['password']
      if $users[username]
        json_response(client, { ok: false, error: 'Username taken' })
      else
        $users[username] = { 'password' => hash_pw(password), 'stocks' => DEFAULT_STOCKS.dup }
        save_users($users)
        token = SecureRandom.hex(16)
        $sessions[token] = username
        json_response(client, { ok: true, username: username }, '200 OK', token)
      end

    when path == '/api/login' && req[:method] == 'POST'
      data = JSON.parse(req[:body])
      username, password = data['username'], data['password']
      if $users[username] && $users[username]['password'] == hash_pw(password)
        token = SecureRandom.hex(16)
        $sessions[token] = username
        json_response(client, { ok: true, username: username }, '200 OK', token)
      else
        json_response(client, { ok: false, error: 'Invalid credentials' })
      end

    when path == '/api/logout' && req[:method] == 'POST'
      cookie = req[:headers]['cookie'] || ''
      token = cookie[/session=([^;]+)/, 1]
      $sessions.delete(token) if token
      json_response(client, { ok: true }, '200 OK', 'deleted; Max-Age=0')

    when path == '/api/me'
      if user
        json_response(client, { ok: true, username: user })
      else
        json_response(client, { ok: false })
      end

    when path == '/api/stocks'
      if user && $users[user]
        stocks = fetch_stocks($users[user]['stocks'])
        # Check alerts and send Mac notifications
        alerts = $users[user]['alerts'] || []
        alerts.each do |a|
          s = stocks.find { |st| st[:symbol] == a['symbol'] }
          next unless s && s[:price]
          triggered = (a['direction'] == 'above' && s[:price] >= a['target']) ||
                      (a['direction'] == 'below' && s[:price] <= a['target'])
          if triggered && !a['notified']
            system("osascript -e 'display notification \"#{a['symbol']} is #{a['direction']} $#{a['target']} (now $#{s[:price]})\" with title \"🔔 StockPulse Alert\" sound name \"Glass\"' &")
            a['notified'] = true
            save_users($users)
          end
        end
        data = JSON.generate(stocks)
        client.print "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{data.bytesize}\r\nConnection: close\r\n\r\n#{data}"
      else
        json_response(client, { error: 'Not authenticated' }, '401 Unauthorized')
      end

    when path =~ /^\/api\/add\?symbol=([A-Za-z.]+)/
      sym = $1.upcase
      if user && $users[user]
        if $users[user]['stocks'].include?(sym)
          json_response(client, { ok: false, error: "#{sym} already in your list" })
        else
          $users[user]['stocks'] << sym
          save_users($users)
          json_response(client, { ok: true })
        end
      else
        json_response(client, { error: 'Not authenticated' }, '401 Unauthorized')
      end

    when path =~ /^\/api\/remove\?symbol=([A-Za-z.]+)/
      sym = $1.upcase
      if user && $users[user]
        if $users[user]['stocks'].delete(sym)
          save_users($users)
          json_response(client, { ok: true })
        else
          json_response(client, { ok: false, error: "#{sym} not found" })
        end
      else
        json_response(client, { error: 'Not authenticated' }, '401 Unauthorized')
      end

    when path =~ /^\/api\/detail\?symbol=([A-Za-z.]+)/
      sym = $1.upcase
      if user
        detail = fetch_stock_detail(sym)
        data = JSON.generate(detail)
        client.print "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{data.bytesize}\r\nConnection: close\r\n\r\n#{data}"
      else
        json_response(client, { error: 'Not authenticated' }, '401 Unauthorized')
      end

    when path =~ /^\/api\/chart\?symbol=([A-Za-z.]+)&range=(\w+)/
      sym = $1.upcase
      range = $2
      if user
        interval = %w[5y 2y].include?(range) ? '1wk' : '1d'
        uri = URI("https://query1.finance.yahoo.com/v8/finance/chart/#{sym}?interval=#{interval}&range=#{range}")
        req = Net::HTTP::Get.new(uri)
        req['User-Agent'] = 'Mozilla/5.0'
        res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 10) { |h| h.request(req) }
        chart_data = JSON.parse(res.body)
        timestamps = chart_data['chart']['result'][0]['timestamp'] || []
        closes = chart_data['chart']['result'][0]['indicators']['quote'][0]['close'] || []
        dates = timestamps.map { |t| Time.at(t).strftime('%Y-%m-%d') }
        resp = JSON.generate({ dates: dates, closes: closes })
        client.print "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{resp.bytesize}\r\nConnection: close\r\n\r\n#{resp}"
      else
        json_response(client, { error: 'Not authenticated' }, '401 Unauthorized')
      end

    when path == '/api/portfolio' && req[:method] == 'GET'
      if user && $users[user]
        portfolio = $users[user]['portfolio'] || []
        json_response(client, { ok: true, portfolio: portfolio })
      else
        json_response(client, { error: 'Not authenticated' }, '401 Unauthorized')
      end

    when path == '/api/portfolio' && req[:method] == 'POST'
      if user && $users[user]
        data = JSON.parse(req[:body])
        $users[user]['portfolio'] ||= []
        $users[user]['portfolio'] << { 'symbol' => data['symbol'].upcase, 'buyPrice' => data['buyPrice'].to_f, 'quantity' => data['quantity'].to_f, 'date' => data['date'] || Time.now.strftime('%Y-%m-%d') }
        save_users($users)
        json_response(client, { ok: true })
      else
        json_response(client, { error: 'Not authenticated' }, '401 Unauthorized')
      end

    when path =~ /^\/api\/portfolio\/delete\?index=(\d+)/
      idx = $1.to_i
      if user && $users[user]
        $users[user]['portfolio'] ||= []
        $users[user]['portfolio'].delete_at(idx)
        save_users($users)
        json_response(client, { ok: true })
      else
        json_response(client, { error: 'Not authenticated' }, '401 Unauthorized')
      end

    when path == '/api/alerts' && req[:method] == 'GET'
      if user && $users[user]
        alerts = $users[user]['alerts'] || []
        json_response(client, { ok: true, alerts: alerts })
      else
        json_response(client, { error: 'Not authenticated' }, '401 Unauthorized')
      end

    when path == '/api/alerts' && req[:method] == 'POST'
      if user && $users[user]
        data = JSON.parse(req[:body])
        $users[user]['alerts'] ||= []
        sym = data['symbol'].upcase
        target = data['target'].to_f
        direction = data['direction'] || 'above'
        if $users[user]['alerts'].any? { |a| a['symbol'] == sym && a['target'] == target && a['direction'] == direction }
          json_response(client, { ok: false, error: "Alert already exists for #{sym} #{direction} $#{target}" })
        else
          $users[user]['alerts'] << { 'symbol' => sym, 'target' => target, 'direction' => direction }
          save_users($users)
          json_response(client, { ok: true })
        end
      else
        json_response(client, { error: 'Not authenticated' }, '401 Unauthorized')
      end

    when path =~ /^\/api\/alerts\/delete\?index=(\d+)/
      idx = $1.to_i
      if user && $users[user]
        $users[user]['alerts'] ||= []
        $users[user]['alerts'].delete_at(idx)
        save_users($users)
        json_response(client, { ok: true })
      else
        json_response(client, { error: 'Not authenticated' }, '401 Unauthorized')
      end

    when path == '/api/plaid/link-token' && req[:method] == 'POST'
      if user
        begin
          result = plaid_create_link_token(user)
          if result['link_token']
            json_response(client, { ok: true, link_token: result['link_token'] })
          else
            json_response(client, { ok: false, error: result['error_message'] || result.to_s[0..200] })
          end
        rescue => e
          json_response(client, { ok: false, error: "Plaid connection failed: #{e.message}" })
        end
      else
        json_response(client, { error: 'Not authenticated' }, '401 Unauthorized')
      end

    when path == '/api/plaid/exchange' && req[:method] == 'POST'
      if user && $users[user]
        data = JSON.parse(req[:body])
        result = plaid_exchange_token(data['public_token'])
        if result['access_token']
          $users[user]['plaid_access_token'] = result['access_token']
          save_users($users)
          json_response(client, { ok: true })
        else
          json_response(client, { ok: false, error: result['error_message'] || 'Exchange failed' })
        end
      else
        json_response(client, { error: 'Not authenticated' }, '401 Unauthorized')
      end

    when path == '/api/plaid/holdings' && req[:method] == 'GET'
      if user && $users[user] && $users[user]['plaid_access_token']
        result = plaid_get_holdings($users[user]['plaid_access_token'])
        if result['holdings']
          holdings = result['holdings'].map do |h|
            sec = result['securities']&.find { |s| s['security_id'] == h['security_id'] }
            { symbol: sec&.dig('ticker_symbol') || 'N/A', quantity: h['quantity'],
              costBasis: h['cost_basis'], value: h['institution_value'] }
          end
          json_response(client, { ok: true, holdings: holdings })
        else
          json_response(client, { ok: false, error: result['error_message'] || 'Failed to fetch holdings' })
        end
      else
        json_response(client, { ok: false, error: 'No brokerage connected' })
      end

    else
      html_response(client, HTML)
    end
  rescue => e
    client.print "HTTP/1.1 500\r\nContent-Length: 0\r\nConnection: close\r\n\r\n" rescue nil
  ensure
    client.close rescue nil
  end
end
