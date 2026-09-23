# DX9HERMES

یک نصب‌کننده و ابزار مدیریت یکپارچه که **Hermes Agent** (ایجنت هوش مصنوعی با گیت‌وی تلگرام) و
**9Router** (روتر/proxy مدل‌های زبانی، سازگار با OpenAI API) را با هم ترکیب می‌کند —
با یک منوی ساده و یک دکمه برای آپدیت.

## چرا این پروژه

نمونه‌های موجود (`hermes-quickstart`، `hermes-9router-mimo`، `Hermes-Agent-Zes`) هرکدام یکی از
این‌ها را دارند: نصب یک‌خطی، مستندسازی معماری، یا اسکریپت‌های Termux — اما هیچ‌کدام یک CLI منوی
تعاملی با آپدیت یک‌دکمه‌ای و rollback خودکار ندارند. DX9HERMES دقیقاً همین خلأ را پر می‌کند.

## معماری

```
Telegram  <-->  Hermes Agent (gateway)  <-->  9Router (127.0.0.1:20128)
                                                    |
                                                    v
                                        Free/paid model providers
```

9Router هرگز روی رابط عمومی bind نمی‌شود؛ فقط روی loopback گوش می‌دهد و از طریق Caddy
(روی IP خام) یا Cloudflare Tunnel (روی دامنه) در دسترس قرار می‌گیرد.

## نصب یک‌خطی (پس از push کردن مخزن روی گیت‌هاب)

```bash
sudo bash <(curl -Ls https://raw.githubusercontent.com/COD-DEXTER/DX-9HERMES/main/main.sh)
```

`main.sh` مخزن را خودش clone می‌کند و هر چیزی که با env var ندهید را به‌صورت
تعاملی از شما می‌پرسد (توکن ربات، آی‌دی مالک، آی‌دی‌های اضافه، و این‌که دامنه‌ی
Cloudflare دارید یا نه). حتماً با `bash <(curl ...)` اجرا شود، نه `curl | bash` —
چون در حالت pipe ورودی ترمینال برای سؤال‌ها در دسترس نمی‌ماند.

اگر می‌خواهید کاملاً بدون سؤال هم اجرا شود (مثلاً برای اسکریپت‌نویسی)، همان متغیرها
را از قبل بدهید:

```bash
TELEGRAM_BOT_TOKEN=xxxxx TELEGRAM_OWNER_ID=123456789 \
sudo -E bash <(curl -Ls https://raw.githubusercontent.com/COD-DEXTER/DX-9HERMES/main/main.sh)
```

## پیش‌نیازهای نصب

فقط این‌ها را باید بدهید (بقیه خودکار است):

| متغیر | توضیح |
|---|---|
| `TELEGRAM_BOT_TOKEN` | از @BotFather |
| `TELEGRAM_OWNER_ID` | آی‌دی عددی شما، از @userinfobot |
| `TELEGRAM_ALLOWED_IDS` | اختیاری، آی‌دی‌های دیگر مجاز (comma-separated) |
| `CLOUDFLARE_API_TOKEN`, `CF_ZONE`, `CF_SUBDOMAIN` | اختیاری — اگر دامنه Cloudflare دارید |
| `ROUTER_VERSION_PIN` | اختیاری — نسخه‌ی مشخص 9Router (مثلاً `1.2.3`) به‌جای همیشه `latest` |
| `HERMES_INSTALL_REF` | اختیاری — commit hash یا tag مشخص Hermes Agent به‌جای همیشه `main` |

نصب مستقیم از یک چک‌اوت محلی (بدون کلون از گیت‌هاب) هم همیشه کار می‌کند:

```bash
TELEGRAM_BOT_TOKEN=xxxxx TELEGRAM_OWNER_ID=123456789 sudo -E ./install.sh
```

بدون دامنه هم کار می‌کند — نصب اول همیشه روی IP سرور با HTTPS (Caddy) بالا می‌آید؛
بعداً هر وقت دامنه گرفتید با گزینه ۵ منو سوییچ کنید.

### سازگاری با انواع سرور

نصب‌کننده روی هر توزیع لینوکسی با یکی از این مدیر‌های پکیج کار می‌کند: `apt`
(Debian/Ubuntu)، `dnf`/`yum` (RHEL/Rocky/Alma/Fedora)، `zypper` (openSUSE)، `apk`
(Alpine)، `pacman` (Arch). Caddy و cloudflared به‌صورت باینری استاتیک از منابع
رسمی خودشان دانلود می‌شوند (نه از ریپوی apt)، پس به یک ریپوی خاص وابسته نیستند.
اگر یک مخزن apt خراب/قدیمی باشد (خطای ۴۰۴ روی `security.debian.org` و مشابه آن)،
اسکریپت چند بار retry می‌کند و اگر باز هم آن یک مخزن مشکل داشت، به‌جای متوقف شدن کل
نصب، با بقیه‌ی مخزن‌هایی که درست refresh شدند ادامه می‌دهد.

اگر توزیع Debian شما دیگر end-of-life شده باشد (مثلاً Debian 11 "bullseye" که
پشتیبانی LTS آن ۳۱ آگوست ۲۰۲۶ تمام شد) و بسته‌ها روی `deb.debian.org` /
`security.debian.org` با خطای ۴۰۴ روبه‌رو بشن، اسکریپت خودش این حالت رو تشخیص
می‌ده، منابع apt رو موقتاً به `archive.debian.org` (که نسخه‌های EOL رو برای همیشه
نگه می‌داره) سوییچ می‌کنه و ادامه می‌ده — نیازی به دخالت دستی نیست. (فایل اصلی
`/etc/apt/sources.list` قبل از تغییر در `/etc/apt/sources.list.dx9hermes.bak`
بکاپ می‌شه.) توصیه می‌شه در اولین فرصت به Debian 12 یا 13 آپگرید کنید چون
Debian 11 دیگه هیچ آپدیت امنیتی رسمی نمی‌گیره.

## اجرای منو

```
dx9hermes
```

هر بار بنر و وضعیت زنده سرویس‌ها + منوی زیر را نشان می‌دهد:

```
1  Install DX9HERMES (Hermes + 9Router)
2  Show Status
3  Test Telegram Bot Connection
4  Remove / Uninstall
5  Set Domain / Cloudflare Subdomain
6  Manage Bot Access (Add / Remove Allowed Users)
7  Change AI Model (Quick switch)
8  Reconfigure Free Provider (New Combo)
9  Change 9Router Port / Bind Address
10 Restart Services
11 View Logs
12 Backup / Restore Config
13 Reset Configuration
14 Switch Access Mode
15 Check For Update      <-- همون دکمه آپدیت یک‌کلیکه 9Router
16 About
0  Exit
```

### آپدیت یک‌دکمه‌ای (گزینه ۱۵)

`scripts/update.sh` قبل از هر آپدیت یک snapshot از نسخه فعلی 9Router و کانفیگ می‌گیرد،
آپدیت را انجام می‌دهد، یک health-check واقعی به `http://127.0.0.1:20128/v1/models` می‌زند،
و اگر شکست بخورد **به‌صورت خودکار** به همان نسخه و کانفیگ قبلی برمی‌گردد — هیچ‌وقت استک شما
نصفه‌کاره رها نمی‌شود.

## امنیت — حتماً بخوانید

- **9Router واقعاً چند CVE واقعی RCE داشته** (نه فقط یک نگرانی نظری): زنجیره‌ی
  «پسورد پیش‌فرض + دور زدن گیت local-only با spoof هدر `Host` + اجرای آرگومان‌های
  اعتبارسنجی‌نشده در ثبت پلاگین MCP» — `CVE-2026-46339` (بدون احراز هویت، نسخه‌های
  ۰.۴.۳۰ تا ۰.۴.۳۶)، `CVE-2026-63732` (زنجیره‌ی پسورد پیش‌فرض، نسخه ۰.۴.۵۹)، و
  `CVE-2026-62312` (احراز‌هویت‌شده، تا قبل از ۰.۵.۲). همه‌شون تا نسخه‌ی **۰.۵.۲**
  فیکس شدن. این نصب‌کننده حالا بعد از نصب `9router --version` رو چک می‌کنه و اگه
  زیر ۰.۵.۲ بود، نصب رو متوقف می‌کنه (`ROUTER_VERSION_PIN` رو خالی بذار یا حداقل
  رو ۰.۵.۲ ست کن).
- 9Router فقط روی `127.0.0.1` باز می‌شه و پشت Caddy/Cloudflare با یک مسیر مخفی
  تصادفی قرار می‌گیره — این جلوی حدس زدن/کراول شدن URL رو می‌گیره. لایه‌ی ورود
  واقعی همون پسورد داشبورد خودِ 9Router هست (دیگه یک پسورد جدا و اضافه‌ی Caddy
  جلوی اون نیست)؛ این جایگزین آپدیت نسخه نیست؛ زنجیره‌ی بالا از هر کلاینتی که
  به ۱۲۷.۰.۰.۱:۲۰۱۲۸ برسه (مثلاً یک سرویس دیگه روی همین سرور) قابل اجراست.
- پسورد اولیه‌ی داشبورد (`INITIAL_PASSWORD`) هر نصب **رندوم** تولید می‌شه (نه یک
  مقدار ثابت مثل `1234`/`123456`) — دقیقاً چون همین «پسورد پیش‌فرض قابل‌حدس» یکی از
  سه حلقه‌ی زنجیره‌ی CVE بالاست. پسورد واقعی بعد از نصب از طریق تلگرام برات
  فرستاده می‌شه.
- `REQUIRE_API_KEY` روی 9Router پیش‌فرضش `false` هست (دقیقاً مطابق پیش‌فرض خودِ
  9Router) — یعنی `/v1/*` بدون کلید هم جواب می‌ده. این امن‌ه فقط چون 9Router روی
  ۱۲۷.۰.۰.۱ محدوده و هیچ‌وقت مستقیم از بیرون در دسترس نیست. اگه می‌خوای یک لایه‌ی
  دفاعی اضافه داشته باشی، از داشبورد (Settings → API Keys) یک کلید بساز، توی
  `/etc/dx9hermes/9router.env` مقدار `REQUIRE_API_KEY=true` رو ست کن، کلید رو در
  `OPENAI_API_KEY` داخل `/etc/dx9hermes/hermes.env` هم بذار، و
  `scripts/configure-hermes-model.sh` رو دوباره اجرا کن تا Hermes هم هماهنگ بشه.
- `JWT_SECRET` و `API_KEY_SECRET` هر بار نصب رندوم تولید می‌شوند، هیچ‌وقت مقدار پیش‌فرض ندارند.
- فایل‌های حساس (`/etc/dx9hermes/*.env`, `/var/lib/9router`) با `chmod 600/700` و
  مالکیت کاربر سرویس (`dx9hermes`, نه root) نگه داشته می‌شوند.

## اتصال Hermes ↔ 9Router (مدل، URL، API Key)

- Hermes مستقیم به `http://127.0.0.1:20128/v1` (Custom / OpenAI-compatible،
  حالت Auto-detect که خودش معادل Chat Completions رو برای این نوع endpoint
  تشخیص می‌ده) وصل می‌شه.
- **اسم مدل هیچ‌جا هارد-کد نیست.** بعد از بالا اومدن 9Router، اسکریپت
  `scripts/configure-hermes-model.sh` خودش از `GET /v1/models` واقعی می‌پرسه چه
  مدل‌هایی الان فعالن، یکی (ترجیحاً یکی با `free` توی اسمش) رو انتخاب می‌کنه و با
  `hermes config set model.provider/model.base_url/model.default` تنظیمش می‌کنه —
  چون نام Providerهای رایگان no-auth روی 9Router (مثل مسیر OpenCode/MiMo) بین
  نسخه‌ها عوض می‌شه و همین چند روز اخیر یک بار با خطای `403 FreeTierError` از کار
  افتاده بود؛ حدس زدن یک اسم ثابت دقیقاً همون چیزیه که این نصب‌کننده ازش فرار می‌کنه.
- اگه 9Router تازه نصب شده باشه، `/v1/models` احتمالاً **خالیه** — چون حتی
  Providerهای رایگان no-auth هم باید یک‌بار دستی از داشبورد Connect بشن (این یکی
  API/CLI مستندی نداره که بشه خودکارش کرد). در این حالت، اسکریپت `model.provider`
  و `model.base_url` رو تنظیم می‌کنه ولی `model.default` رو دست‌نخورده می‌ذاره و
  دقیقاً می‌گه چیکار کنی؛ بعدش از منو گزینه ۷ (Change Model) رو بزن تا دوباره چک کنه.
- کلید API که به Hermes داده می‌شه یک مقدار غیرحساس (`local-no-auth`) هست، نه یک
  سکرت واقعی — چون `REQUIRE_API_KEY=false`، 9Router اصلاً بهش نگاه نمی‌کنه؛ فقط
  چون بعضی کلاینت‌ها (از جمله Hermes) فیلد کلید خالی رو قبول نمی‌کنن یک مقدار غیر
  خالی لازمه.
- **تست E2E واقعاً از داخل خودِ Hermes رد می‌شه، نه فقط curl به 9Router.** بعد از
  تنظیم `model.provider`/`model.base_url`، اسکریپت یک `hermes chat --model
  <candidate> -q "..."` واقعی (مستندشده در مستندات رسمی Hermes، حالت
  non-interactive تک-پرسشی با override مدل فقط برای همون یک اجرا) رو اجرا
  می‌کنه. **model.default فقط وقتی commit می‌شه که این تست واقعاً موفق بشه** —
  یعنی یک مدل خراب هیچ‌وقت به‌عنوان مدل فعال Hermes باقی نمی‌مونه، حتی اگه
  9Router خودش به‌تنهایی جواب درست بده. نتیجه در یکی از این دو فایل ثبت می‌شه:
  - `/etc/dx9hermes/model_e2e_verified` → واقعاً از مسیر Hermes تست و تأیید شده.
  - `/etc/dx9hermes/router_model_e2e_verified` → فقط 9Router مستقیم تست شده
    (وقتی باینری `hermes` برای کاربر سرویس در دسترس نبوده)؛ پیام‌های نصب و
    تلگرام هم صریحاً همین تفاوت رو اعلام می‌کنن، نه یک ادعای گمراه‌کننده‌ی
    «Hermes → 9Router → Model verified».

## ساختار مخزن

```
main.sh                  بوت‌استرپ تک‌خطی (bash <(curl -Ls .../main.sh)) — کلون + سؤال‌های تعاملی
install.sh              نصب غیرتعاملی، idempotent
bin/dx9hermes            CLI منوی تعاملی اصلی
lib/ui.sh                بنر + منو + رنگ‌ها (مشترک بین install.sh و CLI)
scripts/update.sh         آپدیت یک‌دکمه‌ای با snapshot/rollback
scripts/manage-access.sh  افزودن/حذف کاربران مجاز تلگرام
scripts/cf-tunnel.sh       ساخت Cloudflare Tunnel از طریق API
scripts/alert.sh           هشدار تلگرامی وقتی سرویسی کرش می‌کند (systemd OnFailure)
systemd/*.service          یونیت‌های 9router، hermes-gateway، alert
```

## نکات پیاده‌سازی که باید در زمان نصب واقعی تأیید شوند

این پروژه یک اسکلت کامل و قابل‌اجراست، اما چند نکته وابسته به نسخه‌های در حال تغییر
9Router/Hermes هست که باید موقع نصب واقعی چک شوند (کامنت‌گذاری شده در کد):

- نام دقیق پروایدر رایگان فعلی در 9Router (`configure_free_provider` در `install.sh`).
- دستور دقیق ساخت local API key در نسخه‌ی نصب‌شده‌ی 9Router (`write_hermes_env`).
- مخزن رسمی و به‌روز Hermes Agent برای نصب (فعلاً از اسکریپت نصب رسمی NousResearch استفاده می‌شود).

## لایسنس

MIT
