#!/usr/bin/env python3
"""
Weather app with dress recommendations.
API key retrieved from HashiCorp Vault at runtime — no hardcoded secrets.
"""

import json
import os
import urllib.request
import urllib.parse
import urllib.error
from http.server import HTTPServer, BaseHTTPRequestHandler

VAULT_ADDR = os.environ.get("VAULT_ADDR", "http://127.0.0.1:8200")
VAULT_TOKEN = os.environ.get("VAULT_TOKEN", "")
DEFAULT_CITY = "Sibiu"


def vault_get(path):
    req = urllib.request.Request(
        f"{VAULT_ADDR}/v1/{path}",
        headers={"X-Vault-Token": VAULT_TOKEN}
    )
    with urllib.request.urlopen(req, timeout=5) as r:
        return json.loads(r.read())["data"]


def get_weather(city, api_key):
    url = "https://api.openweathermap.org/data/2.5/weather?" + urllib.parse.urlencode({
        "q": city,
        "appid": api_key,
        "units": "metric"
    })
    with urllib.request.urlopen(url, timeout=5) as r:
        return json.loads(r.read())


def dress_advice(temp, condition):
    condition = condition.lower()

    if "thunderstorm" in condition:
        outfit = "⚡ A lightning rod hat and a prayer."
        reason = "Seriously though, stay inside. Nature is angry today."
    elif "snow" in condition:
        outfit = "🧣 Full Arctic explorer mode: coat, boots, gloves, scarf, dignity optional."
        reason = "Unless you enjoy looking like a soggy snowman."
    elif "rain" in condition or "drizzle" in condition:
        outfit = "☂️ A waterproof jacket or just accept your wet fate."
        reason = "Umbrellas exist for a reason. Use one. Be the person who uses one."
    elif "fog" in condition or "mist" in condition:
        outfit = "👻 Anything — nobody can see you anyway."
        reason = "Ideal day to wear that outfit you've been too embarrassed to try."
    elif "clear" in condition:
        if temp > 25:
            outfit = "😎 Sunglasses, shorts, and maximum smugness."
            reason = "You earned this. Everyone else is jealous."
        else:
            outfit = "🌤️ Light layers and sunglasses. Look effortlessly cool."
            reason = "Clear skies demand a good outfit."
    else:
        outfit = "🌥️ Jeans and a light top. The classic 'I have no idea' look."
        reason = "When in doubt, layer up."

    if temp < 0:
        outfit = "🥶 Everything you own. Simultaneously."
        reason = "Why do you live here? Rhetorical question. Stay warm."
    elif temp < 8:
        outfit = "🧥 Heavy coat, scarf, gloves. No negotiations."
        reason = "Your fingers will thank you. Your fingers are non-negotiable."
    elif temp < 15:
        outfit = "🧤 Jacket mandatory. Argue with yourself about the scarf."
        reason = "You'll be cold without it but too warm with it. Welcome to shoulder season."
    elif temp < 20:
        outfit = "👕 Light jacket. Bring it just in case, then carry it all day."
        reason = "It starts cold, gets warm, you panic. Prepare accordingly."
    elif temp >= 35:
        outfit = "🩳 As little as legally and socially acceptable."
        reason = "The sun has declared war. Dress accordingly."

    return outfit, reason


HTML_TEMPLATE = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Weather & What To Wear</title>
  <style>
    * {{ box-sizing: border-box; margin: 0; padding: 0; }}
    body {{
      font-family: 'Segoe UI', sans-serif;
      min-height: 100vh;
      background: {bg};
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      padding: 20px;
    }}
    .card {{
      background: rgba(255,255,255,0.15);
      backdrop-filter: blur(12px);
      border-radius: 24px;
      padding: 40px;
      max-width: 520px;
      width: 100%;
      color: white;
      box-shadow: 0 8px 32px rgba(0,0,0,0.2);
      border: 1px solid rgba(255,255,255,0.2);
    }}
    .search {{
      display: flex;
      gap: 10px;
      margin-bottom: 30px;
    }}
    .search input {{
      flex: 1;
      padding: 12px 18px;
      border-radius: 50px;
      border: none;
      background: rgba(255,255,255,0.25);
      color: white;
      font-size: 16px;
      outline: none;
    }}
    .search input::placeholder {{ color: rgba(255,255,255,0.7); }}
    .search button {{
      padding: 12px 22px;
      border-radius: 50px;
      border: none;
      background: rgba(255,255,255,0.3);
      color: white;
      font-size: 16px;
      cursor: pointer;
      font-weight: bold;
      transition: background 0.2s;
    }}
    .search button:hover {{ background: rgba(255,255,255,0.45); }}
    .city {{ font-size: 28px; font-weight: 700; margin-bottom: 4px; }}
    .condition {{ font-size: 16px; opacity: 0.85; margin-bottom: 20px; text-transform: capitalize; }}
    .temp-row {{
      display: flex;
      align-items: flex-end;
      gap: 16px;
      margin-bottom: 24px;
    }}
    .temp-main {{ font-size: 72px; font-weight: 200; line-height: 1; }}
    .temp-details {{ font-size: 14px; opacity: 0.8; line-height: 1.8; }}
    .divider {{
      border: none;
      border-top: 1px solid rgba(255,255,255,0.2);
      margin: 20px 0;
    }}
    .advice-label {{
      font-size: 12px;
      text-transform: uppercase;
      letter-spacing: 2px;
      opacity: 0.7;
      margin-bottom: 10px;
    }}
    .outfit {{ font-size: 20px; font-weight: 600; margin-bottom: 8px; }}
    .reason {{ font-size: 15px; opacity: 0.85; line-height: 1.5; font-style: italic; }}
    .error {{
      background: rgba(255,80,80,0.3);
      border-radius: 12px;
      padding: 16px;
      text-align: center;
    }}
    .vault-note {{
      margin-top: 24px;
      font-size: 11px;
      opacity: 0.5;
      text-align: center;
    }}
  </style>
</head>
<body>
  <div class="card">
    <form class="search" method="get" action="/">
      <input type="text" name="city" placeholder="Search city..." value="{city_input}">
      <button type="submit">Go</button>
    </form>
    {content}
    <p class="vault-note">🔒 API key retrieved at runtime from HashiCorp Vault</p>
  </div>
</body>
</html>"""


def weather_content(city):
    try:
        secret = vault_get("secret/weather")
        api_key = secret["api_key"]
        data = get_weather(city, api_key)
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return '<div class="error">🌍 City not found. Try again.</div>', "linear-gradient(135deg, #667eea, #764ba2)"
        return f'<div class="error">Weather API error: {e.code}</div>', "linear-gradient(135deg, #667eea, #764ba2)"
    except Exception as e:
        return f'<div class="error">Error: {e}</div>', "linear-gradient(135deg, #667eea, #764ba2)"

    temp = data["main"]["temp"]
    feels_like = data["main"]["feels_like"]
    humidity = data["main"]["humidity"]
    condition = data["weather"][0]["description"]
    city_name = data["name"]
    country = data["sys"]["country"]
    wind = data["wind"]["speed"]

    outfit, reason = dress_advice(temp, condition)

    # Background based on temperature
    if temp < 0:
        bg = "linear-gradient(135deg, #1a1a2e, #16213e)"
    elif temp < 10:
        bg = "linear-gradient(135deg, #2c3e50, #3498db)"
    elif temp < 20:
        bg = "linear-gradient(135deg, #2980b9, #6dd5fa)"
    elif temp < 28:
        bg = "linear-gradient(135deg, #f093fb, #f5576c)"
    else:
        bg = "linear-gradient(135deg, #f7971e, #ffd200)"

    content = f"""
    <div class="city">{city_name}, {country}</div>
    <div class="condition">{condition}</div>
    <div class="temp-row">
      <div class="temp-main">{temp:.0f}°</div>
      <div class="temp-details">
        Feels like {feels_like:.0f}°C<br>
        Humidity {humidity}%<br>
        Wind {wind} m/s
      </div>
    </div>
    <hr class="divider">
    <div class="advice-label">👗 What to wear</div>
    <div class="outfit">{outfit}</div>
    <div class="reason">{reason}</div>"""

    return content, bg


class AppHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        params = urllib.parse.parse_qs(parsed.query)
        city = params.get("city", [DEFAULT_CITY])[0].strip() or DEFAULT_CITY

        content, bg = weather_content(city)
        html = HTML_TEMPLATE.format(
            bg=bg,
            city_input=city if city != DEFAULT_CITY else "",
            content=content
        )

        encoded = html.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", len(encoded))
        self.end_headers()
        self.wfile.write(encoded)


if __name__ == "__main__":
    if not VAULT_TOKEN:
        print("ERROR: VAULT_TOKEN environment variable not set.")
        raise SystemExit(1)
    print(f"App listening on http://127.0.0.1:5000 (default city: {DEFAULT_CITY})")
    HTTPServer(("127.0.0.1", 5000), AppHandler).serve_forever()
