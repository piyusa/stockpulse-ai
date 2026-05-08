require 'socket'
require 'net/http'
require 'json'
require 'uri'
require 'securerandom'
require 'digest'

PORT = (ENV["PORT"] || 8888).to_i
USERS_FILE = ENV.fetch('USERS_FILE', File.expand_path('~/.stock_users.json'))
DEFAULT_STOCKS = %w[AAPL MSFT NVDA GOOG AMZN META TSM AVGO ORCL CRM]

POSITIVE_WORDS = %w[surge rally gain rise jump soar beat bullish upgrade buy strong growth boom record high peak outperform positive optimistic profit revenue earnings exceeded].freeze
NEGATIVE_WORDS = %w[drop fall crash decline plunge miss bearish downgrade sell weak loss slump low cut risk fear concern negative pessimistic layoff recession tariff].freeze

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
      # Intraday data for EOD prediction
      uri_intra = URI("https://query1.finance.yahoo.com/v8/finance/chart/#{sym}?interval=5m&range=1d")
      req = Net::HTTP::Get.new(uri_intra)
      req['User-Agent'] = 'Mozilla/5.0'
      res = Net::HTTP.start(uri_intra.host, uri_intra.port, use_ssl: true, open_timeout: 5, read_timeout: 5) { |h| h.request(req) }
      data = JSON.parse(res.body)
      meta = data['chart']['result'][0]['meta']
      intra_closes = data['chart']['result'][0]['indicators']['quote'][0]['close'].compact

      price = meta['regularMarketPrice']
      prev_close = meta['chartPreviousClose']

      # 5-day data for trend
      uri5 = URI("https://query1.finance.yahoo.com/v8/finance/chart/#{sym}?interval=1d&range=5d")
      req5 = Net::HTTP::Get.new(uri5)
      req5['User-Agent'] = 'Mozilla/5.0'
      res5 = Net::HTTP.start(uri5.host, uri5.port, use_ssl: true, open_timeout: 5, read_timeout: 5) { |h| h.request(req5) }
      data5 = JSON.parse(res5.body)
      closes5 = data5['chart']['result'][0]['indicators']['quote'][0]['close'].compact
      trend = closes5.size >= 2 ? ((closes5.last - closes5.first) / closes5.first * 100) : 0

      # EOD prediction: linear regression on intraday 5-min candles, extrapolate to market close (78 intervals in 6.5hr day)
      predicted = nil
      if intra_closes.size >= 5
        n = intra_closes.size
        total_intervals = 78 # 6.5 hours * 12 intervals/hr
        x_mean = (n - 1) / 2.0
        y_mean = intra_closes.sum / n.to_f
        num = intra_closes.each_with_index.sum { |y, x| (x - x_mean) * (y - y_mean) }
        den = (0...n).sum { |x| (x - x_mean) ** 2 }
        slope = den != 0 ? num / den : 0
        intercept = y_mean - slope * x_mean
        predicted = (intercept + slope * (total_intervals - 1)).round(2)
      end

      headlines = fetch_news(sym)
      news_sentiment = analyze_sentiment(headlines)
      price_sent = if price > (closes5.sum / closes5.size.to_f) * 1.01 then 1
                   elsif price < (closes5.sum / closes5.size.to_f) * 0.99 then -1
                   else 0 end
      news_val = news_sentiment[:score] > 20 ? 1 : news_sentiment[:score] < -20 ? -1 : 0
      combined = price_sent + news_val
      overall = combined > 0 ? 'bullish' : combined < 0 ? 'bearish' : 'neutral'

      { symbol: sym, price: price, prevClose: prev_close, trend: trend.round(2),
        predicted: predicted, newsSentiment: news_sentiment[:label],
        newsScore: news_sentiment[:score], headlines: headlines[0..2], overall: overall }
    rescue
      { symbol: sym, price: nil, prevClose: nil, trend: 0, predicted: nil,
        newsSentiment: 'neutral', newsScore: 0, headlines: [], overall: 'neutral' }
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

  # EOD prediction using intraday data
  uri_intra = URI("https://query1.finance.yahoo.com/v8/finance/chart/#{sym}?interval=5m&range=1d")
  req = Net::HTTP::Get.new(uri_intra)
  req['User-Agent'] = 'Mozilla/5.0'
  res_intra = Net::HTTP.start(uri_intra.host, uri_intra.port, use_ssl: true, open_timeout: 5, read_timeout: 5) { |h| h.request(req) }
  intra_data = JSON.parse(res_intra.body)
  intra_closes = intra_data['chart']['result'][0]['indicators']['quote'][0]['close'].compact
  predicted = nil
  if intra_closes.size >= 5
    n = intra_closes.size
    total_intervals = 78
    x_mean = (n - 1) / 2.0
    y_mean = intra_closes.sum / n.to_f
    num = intra_closes.each_with_index.sum { |y, x| (x - x_mean) * (y - y_mean) }
    den = (0...n).sum { |x| (x - x_mean) ** 2 }
    slope = den != 0 ? num / den : 0
    intercept = y_mean - slope * x_mean
    predicted = (intercept + slope * (total_intervals - 1)).round(2)
  end

  # News
  headlines = fetch_news(sym)
  news_sentiment = analyze_sentiment(headlines)

  { symbol: sym, price: price, prevClose: prev_close, high52: high52, low52: low52,
    avg30: avg30, high30: high30, low30: low30, avgVolume: avg_vol,
    predicted: predicted, sentiment: news_sentiment[:label], newsScore: news_sentiment[:score],
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
<style>
  *{box-sizing:border-box}
  body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;background:#0f0f1a;color:#e8e8e8;margin:0;padding:0}
  .container{max-width:1200px;margin:0 auto;padding:20px}
  header{text-align:center;padding:30px 20px;border-bottom:1px solid #1e1e3a;margin-bottom:30px}
  header h1{font-size:28px;color:#fff;margin:0 0 8px}
  header h1 span{color:#00d4ff}
  header p{color:#666;margin:4px 0;font-size:14px}
  .user-bar{display:flex;justify-content:flex-end;align-items:center;gap:12px;margin-bottom:10px}
  .user-bar span{color:#888;font-size:13px}
  .user-bar button{background:#ff525233;color:#ff5252;border:1px solid #ff525244;padding:6px 12px;border-radius:6px;font-size:12px;cursor:pointer}
  .auth-box{max-width:360px;margin:80px auto;background:#16213e;border-radius:12px;padding:30px;border:1px solid #1e1e3a}
  .auth-box h2{color:#00d4ff;margin:0 0 20px;text-align:center}
  .auth-box input{width:100%;background:#0f0f1a;border:1px solid #1e1e3a;color:#eee;padding:12px;border-radius:8px;font-size:14px;margin-bottom:12px}
  .auth-box button{width:100%;padding:12px;border:none;border-radius:8px;font-size:14px;font-weight:600;cursor:pointer;margin-bottom:8px}
  .auth-box .btn-login{background:#00d4ff;color:#000}
  .auth-box .btn-register{background:#16213e;color:#00d4ff;border:1px solid #00d4ff}
  .auth-box .error{color:#ff5252;font-size:12px;text-align:center;margin-bottom:10px}
  .auth-box .toggle{text-align:center;color:#666;font-size:12px;margin-top:10px;cursor:pointer}
  .auth-box .toggle a{color:#00d4ff;text-decoration:none}
  .status{display:inline-block;padding:4px 12px;border-radius:20px;font-size:12px;margin-top:10px}
  .status.live{background:#00e67622;color:#00e676;border:1px solid #00e67644}
  .controls{display:flex;justify-content:center;gap:10px;margin-bottom:20px;flex-wrap:wrap}
  .controls input{background:#16213e;border:1px solid #1e1e3a;color:#eee;padding:10px 14px;border-radius:8px;font-size:14px;width:140px;text-transform:uppercase}
  .controls input::placeholder{color:#556;text-transform:none}
  .controls button{padding:10px 18px;border:none;border-radius:8px;font-size:13px;font-weight:600;cursor:pointer}
  .btn-add{background:#00e676;color:#000}.btn-add:hover{background:#00c853}
  .disclaimer{background:#ff525211;border:1px solid #ff525233;border-radius:8px;padding:12px 16px;margin-bottom:24px;font-size:12px;color:#ff8a80;text-align:center}
  .updated{text-align:center;color:#888;margin-bottom:20px;font-size:13px}
  .table-wrap{overflow-x:auto;border-radius:12px;border:1px solid #1e1e3a;margin-bottom:30px}
  table{width:100%;border-collapse:collapse;min-width:800px}
  th{background:#16213e;padding:14px 10px;text-align:right;font-size:11px;text-transform:uppercase;letter-spacing:.5px;color:#8899aa}
  th:first-child{text-align:left;padding-left:16px}
  td{padding:12px 10px;text-align:right;border-bottom:1px solid #1a1a2e;font-size:13px}
  td:first-child{text-align:left;font-weight:600;padding-left:16px;font-size:14px}
  tr:hover{background:#16213e88}
  .pos{color:#00e676}.neg{color:#ff5252}
  .badge{padding:4px 10px;border-radius:20px;font-size:11px;font-weight:600;white-space:nowrap;display:inline-block}
  .badge.bullish{background:#00e67622;color:#00e676}
  .badge.bearish{background:#ff525222;color:#ff5252}
  .badge.neutral{background:#ffd60022;color:#ffd600}
  .btn-del{background:#ff525233;color:#ff5252;border:1px solid #ff525244;padding:4px 10px;border-radius:6px;font-size:11px;cursor:pointer}
  .btn-del:hover{background:#ff525255}
  h2{color:#fff;font-size:20px;margin:0 0 16px;padding-left:4px}
  .news{display:grid;grid-template-columns:repeat(auto-fill,minmax(340px,1fr));gap:14px;margin-bottom:30px}
  .card{background:#16213e;border-radius:10px;padding:16px;border:1px solid #1e1e3a}
  .card h3{margin:0 0 10px;color:#fff;font-size:14px;display:flex;align-items:center;gap:8px}
  .card ul{margin:0;padding:0 0 0 18px;font-size:12px;color:#aab;line-height:1.6}
  .card li{margin-bottom:4px}
  .methodology{background:#16213e;border-radius:10px;padding:20px;border:1px solid #1e1e3a;font-size:13px;color:#889;line-height:1.7}
  .methodology h3{color:#aaa;margin:0 0 12px;font-size:14px}
  .methodology b{color:#bbc}
  footer{text-align:center;padding:30px;color:#444;font-size:12px;border-top:1px solid #1e1e3a;margin-top:30px}
  .toast{position:fixed;top:20px;right:20px;padding:12px 20px;border-radius:8px;font-size:13px;z-index:999;opacity:0;transition:opacity .3s}
  .toast.show{opacity:1}.toast.success{background:#00e676;color:#000}.toast.error{background:#ff5252;color:#fff}
  .modal-overlay{display:none;position:fixed;top:0;left:0;right:0;bottom:0;background:rgba(0,0,0,.7);z-index:1000;overflow-y:auto;padding:20px}
  .modal{max-width:900px;margin:20px auto;background:#0f0f1a;border-radius:16px;border:1px solid #1e1e3a;padding:30px;position:relative}
  .modal-close{position:absolute;top:16px;right:20px;background:none;border:none;color:#888;font-size:24px;cursor:pointer}
  .modal-close:hover{color:#fff}
  .modal h2{color:#00d4ff;margin:0 0 4px;font-size:24px}
  .modal .price-big{font-size:36px;font-weight:700;margin:10px 0}
  .modal .stats{display:grid;grid-template-columns:repeat(auto-fill,minmax(180px,1fr));gap:12px;margin:20px 0}
  .modal .stat{background:#16213e;border-radius:8px;padding:12px}
  .modal .stat label{display:block;font-size:11px;color:#668;text-transform:uppercase;margin-bottom:4px}
  .modal .stat span{font-size:16px;font-weight:600}
  .chart-container{background:#16213e;border-radius:10px;padding:16px;margin:20px 0}
  .chart-container canvas{width:100%;height:200px}
  .modal .news-list{margin:20px 0}
  .modal .news-list h3{color:#aaa;margin:0 0 12px}
  .modal .news-list li{margin-bottom:8px;font-size:13px;color:#bbc;line-height:1.5}
  @media(max-width:600px){.container{padding:10px}header h1{font-size:22px}.modal{padding:16px}}
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
    <header><h1>📈 <span>StockPulse AI</span></h1><p>Sign in to manage your personal watchlist</p></header>
    <div class="auth-box">
      <h2 id="auth-title">Sign In</h2>
      <div class="error" id="auth-error"></div>
      <input type="text" id="auth-user" placeholder="Username">
      <input type="password" id="auth-pass" placeholder="Password">
      <button class="btn-login" id="auth-btn" onclick="doAuth()">Sign In</button>
      <div class="toggle" id="auth-toggle">Don't have an account? <a onclick="toggleAuth()">Register</a></div>
    </div>
  </div>
  <div id="app-view" style="display:none">
    <div class="user-bar"><span id="user-label"></span><button onclick="logout()">Sign Out</button></div>
    <header>
      <h1>📈 <span>StockPulse AI</span></h1>
      <p>Your Personal Watchlist • Real-Time Prices • Sentiment • Prediction</p>
      <div class="status live" id="status">● LIVE</div>
    </header>
    <div class="controls">
      <input type="text" id="symbolInput" placeholder="e.g. TSLA" maxlength="5">
      <button class="btn-add" onclick="addStock()">+ Add Stock</button>
    </div>
    <div class="disclaimer">⚠️ For informational purposes only. Not financial advice.</div>
    <div class="updated" id="up">Loading...</div>
    <div class="table-wrap">
    <table><thead><tr><th>Ticker</th><th>Price</th><th>Change</th><th>5D Trend</th><th>News</th><th>Signal</th><th>EOD Forecast</th><th></th><th></th></tr></thead>
    <tbody id="tb"></tbody></table>
    </div>
    <h2>📰 Headlines</h2>
    <div class="news" id="news"></div>
    <div class="methodology"><h3>📊 Methodology</h3><b>Sentiment:</b> Keyword analysis of Yahoo Finance headlines.<br><br><b>Signal:</b> Price momentum + news sentiment combined.<br><br><b>Prediction:</b> End-of-day forecast using linear regression on intraday 5-min candles, extrapolated to market close.<br><br><b>Source:</b> Yahoo Finance. Refreshes every 60s.</div>
    <footer>StockPulse AI • stockpulse.ai • Auto-refreshes every 60s</footer>
  </div>
</div>
<script>
let isLogin=true;
function toast(msg,type='success'){const t=document.getElementById('toast');t.textContent=msg;t.className=`toast ${type} show`;setTimeout(()=>t.className='toast',3000);}
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
      return`<tr><td><a href="#" onclick="openDetail('${s.symbol}');return false" style="color:#00d4ff;text-decoration:none">${s.symbol}</a></td><td>$${s.price.toFixed(2)}</td><td class="${cls}">${arr} ${sgn}${pct.toFixed(2)}%</td><td class="${tCls}">${trend}</td><td><span class="badge ${s.newsSentiment}">${s.newsSentiment}</span></td><td><span class="badge ${s.overall}">${s.overall}</span></td><td class="${pCls}">${pred}</td><td>${al}</td><td><button class="btn-del" onclick="removeStock('${s.symbol}')">✕</button></td></tr>`;
    }).join('');
    document.getElementById('news').innerHTML=stocks.filter(s=>s.headlines&&s.headlines.length).map(s=>`<div class="card"><h3>${s.symbol} <span class="badge ${s.newsSentiment}">${s.newsSentiment}</span></h3><ul>${s.headlines.map(h=>`<li>${h}</li>`).join('')}</ul></div>`).join('');
    document.getElementById('up').textContent=`${stocks.length} stocks • Updated: ${new Date().toLocaleString()} • Refreshes every 60s`;
  }catch(e){}
}
checkSession();
setInterval(()=>{if(document.getElementById('app-view').style.display!=='none')update();},60000);

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
      <div class="stat"><label>EOD Forecast</label><span class="${d.predicted>=d.price?'pos':'neg'}">$${d.predicted||'—'}</span></div>
      <div class="stat"><label>News Sentiment</label><span><span class="badge ${d.sentiment}">${d.sentiment} (${d.newsScore})</span></span></div>
    </div>
    <div class="chart-container"><canvas id="priceChart"></canvas></div>
    <div class="news-list"><h3>📰 Latest News</h3><ul>${d.headlines.map(h=>'<li>'+h+'</li>').join('')}</ul></div>
  `;
  drawChart(d.dates,d.closes,d.symbol);
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
        data = JSON.generate(fetch_stocks($users[user]['stocks']))
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

    else
      html_response(client, HTML)
    end
  rescue => e
    client.print "HTTP/1.1 500\r\nContent-Length: 0\r\nConnection: close\r\n\r\n" rescue nil
  ensure
    client.close rescue nil
  end
end
