# MegaBox Server Creator

**Описание / Description**

**RU:** Flutter-приложение для Windows и Android, которое по SSH автоматически настраивает ваш собственный VPS: ставит панель 3X-UI, создаёт inbound VLESS + REALITY и выдаёт готовую ссылку `vless://` и QR-код для клиента.

**EN:** A Flutter app for Windows and Android that automatically configures your own VPS over SSH: installs the 3X-UI panel, creates a VLESS + REALITY inbound, and outputs a ready-to-use `vless://` link and QR code for your client.

---

# Русский

## Что делает приложение

- **Автоматическая установка:** вы вводите IP, SSH-порт, пользователя и пароль, а приложение само ставит 3X-UI и настраивает VLESS + REALITY.
- **Диагностика перед установкой:** проверяет доступность SSH-порта и VLESS-порта с вашего устройства, вход по SSH, ресурсы VPS (RAM, диск), часы, системную версию и уже установленные сервисы. Если SSH-порт не отвечает совсем, приложение предупреждает, что сервер может быть недоступен из вашей сети.
- **Живая статистика:** CPU, RAM, диск и аптайм сервера по SSH.
- **Клиентские ключи:** дополнительные ключи для других устройств с лимитами по IP и трафику, резервный inbound на отдельном порту.
- **Подписка:** генерация ссылки подписки для нескольких клиентов.
- **Маршрутизация:** опциональный прямой выход для доменов `.ru`, `.su`, `.рф`, блокировка торрентов и рекламы, отдельный маршрут для некоторых AI-сервисов через Cloudflare WARP.
- **Журнал и QR:** лог установки в реальном времени и QR-код для быстрого импорта в клиент.
- **Миграция:** скачивание и загрузка базы `x-ui.db` для переноса на новый сервер.

## Требования

**VPS:**
- Ubuntu 20.04+, Debian 10+ или другой Linux с systemd
- Минимум 512 МБ RAM (рекомендуется 1 ГБ+)
- SSH-доступ под `root` или пользователем с `sudo`
- Свободные порты: 443 (VLESS), 8443 (резервный inbound), 2053 (панель)

**Для запуска:**
- Windows 10/11 (версия для ПК) или Android на 64-битном процессоре arm64 (APK)

**Для сборки из исходников:**
- Flutter SDK with Dart 3.13.4+ (as in `pubspec.yaml`)
- Для Android: JDK 17, Android SDK (platform 36, build-tools 36.0.0), NDK 28.2.13676358

## Установка приложения

**Windows:** скачайте архив из раздела Releases или соберите сами (см. ниже) и запустите `megabox_server_creator.exe`.

**Android:** скачайте `MegaBox.apk` из раздела Releases, откройте файл и разрешите установку из этого источника. Если Google Play Защита покажет предупреждение, выберите «Всё равно установить». APK подписан ключом разработчика, а не через Google Play. Для диагностики на телефоне отключите VPN, иначе проверка покажет связь через VPN, а не из вашей сети.

## Пошаговый гайд

1. **Подготовьте VPS.** Возьмите чистый Ubuntu или Debian, запомните IP, SSH-порт, пользователя и пароль.
2. **Откройте приложение** и заполните форму:

   | Поле | Что ввести |
   |------|-----------|
   | IP-адрес VPS | Публичный IPv4 сервера |
   | SSH-порт | По умолчанию 22 |
   | Пользователь | `root` или пользователь с sudo |
   | Пароль | Пароль от этого пользователя |
   | SNI | Домен для REALITY, например `www.google.com` или `cloudflare.com` |
   | Порт VLESS | По умолчанию 443 |
   | Название | Любое имя сервера для вашего списка |

3. **Запустите диагностику** (вкладка «Проверка» или переключатель «Проверить сервер перед установкой»). Если все проверки зелёные, переходите дальше. Если есть предупреждения, посмотрите их в списке проблем.
4. **Нажмите «Развернуть».** Приложение пройдёт этапы:
   - 1/6 подготовка системы (apt, BBR, освобождение порта 443)
   - 2/6 установка 3X-UI без интерактивных вопросов
   - 3/6 генерация ключей (x25519, UUID, shortId)
   - 4/6 создание VLESS REALITY inbound через API
   - 5/6 получение ссылки
   - 6/6 готово
5. **Скопируйте ссылку** `vless://` или покажите QR-код и импортируйте в клиент.

## Клиенты

- **Android:** v2rayNG, V2FlyNG
- **iOS:** Shadowrocket, Stash
- **Windows и macOS:** v2rayN, Clash Verge
- **Linux:** Xray-core, v2ray-core

## Безопасность

- Используйте приложение только на своём сервере и соблюдайте законы страны, в которой вы находитесь и где работает сервер.
- Панель 3X-UI отдаётся по HTTP. Для доступа используйте SSH-туннель или обратный прокси с HTTPS.
- Логин и пароль панели генерируются случайно и показываются в журнале. Сохраните их: после закрытия приложения восстановить их нельзя.
- Сохранённая история серверов хранит ссылки, учётные данные панели и SSH-пароли в локальном хранилище приложения **без шифрования**. Не используйте приложение на чужом компьютере и не храните историю на общих устройствах.
- Ключ SSH-сервера запоминается при первом подключении (Trust On First Use). Если он потом изменился, приложение не подключается и не отправляет пароль. После законной переустановки VPS сбросьте запомненный ключ этого сервера в приложении.

## Сборка из исходников

```bash
git clone https://github.com/<ваш-логин>/megabox_server_creator.git
cd megabox_server_creator
flutter pub get

# Windows
flutter run -d windows
flutter build windows --release        # результат: build\windows\x64\runner\Release\

# Android
flutter build apk --release --split-per-abi --target-platform android-arm64
```

На Windows при сборке Android удобно запускать `build_android_auto.bat`: он ставит JDK, Android SDK и NDK в `C:\Android` и собирает APK. Если путь к пользователю содержит кириллицу, скрипт переносит кэш Pub и временные файлы в `C:\Android`, иначе сборка CMake/Ninja может упасть.

## Тесты

```bash
flutter test
```

Тесты покрывают генерацию скриптов для VPS, разбор вывода диагностики, работу с историей серверов, SQL-запросы к базе 3X-UI и простой UI. Часть тестов работает на локальном TCP-сокете и не требует сервера.

## Структура проекта

```
lib/
├── main.dart                     # точка входа, отдельные раскладки для ПК и телефона
├── screens/                      # главный экран, серверы, диагностика
├── services/
│   ├── ssh_service.dart          # SSH-установка и настройка
│   ├── diagnostics_service.dart  # проверки перед установкой
│   ├── api_service.dart          # клиент API 3X-UI
│   ├── server_management_service.dart
│   └── storage_service.dart      # локальная история серверов
├── models/                       # модели конфигурации и результатов
├── widgets/                      # виджеты, карточки ссылок, журнал
└── theme/                        # оформление
android/                          # сборка Android
windows/                          # сборка Windows
tool/                             # скрипты сборки Android для Windows
test/                             # тесты
```

Подробнее об архитектуре см. [ARCHITECTURE.md](ARCHITECTURE.md).

## Лицензия

MIT, см. файл [LICENSE](LICENSE).

## Благодарности

- [3X-UI](https://github.com/mhsanaei/3x-ui) — панель для Xray
- [Xray-core](https://github.com/XTLS/Xray-core) — прокси-ядро
- [Flutter](https://flutter.dev/) — UI-фреймворк
- [dartssh2](https://pub.dev/packages/dartssh2) — SSH-клиент для Dart

---

# English

## What the app does

- **Automatic setup:** enter the IP, SSH port, user and password, and the app installs 3X-UI and configures VLESS + REALITY by itself.
- **Pre-install diagnostics:** checks whether the SSH and VLESS ports respond from your device, whether SSH login works, the VPS resources (RAM, disk), clock sync, OS version and already installed services. If the SSH port does not answer at all, the app warns that the server may be unreachable from your network.
- **Live statistics:** CPU, RAM, disk and uptime over SSH.
- **Client keys:** extra keys for other devices with IP and traffic limits, and a backup inbound on a separate port.
- **Subscription:** a subscription link for several clients.
- **Routing:** optional direct routing for `.ru`, `.su`, `.рф` domains, torrent and ad blocking, and a dedicated route for some AI services through Cloudflare WARP.
- **Log and QR:** a live install log and a QR code for quick import into a client.
- **Migration:** download and upload the `x-ui.db` database to move to a new server.

## Requirements

**VPS:**
- Ubuntu 20.04+, Debian 10+, or another systemd-based Linux
- At least 512 MB RAM (1 GB+ recommended)
- SSH access as `root` or a user with `sudo`
- Free ports: 443 (VLESS), 8443 (backup inbound), 2053 (panel)

**To run:**
- Windows 10/11 (desktop) or Android on a 64-bit arm64 CPU (APK)

**To build from source:**
- Flutter SDK with Dart 3.13.4+ (as in `pubspec.yaml`)
- For Android: JDK 17, Android SDK (platform 36, build-tools 36.0.0), NDK 28.2.13676358

## Installing the app

**Windows:** download the archive from Releases, or build it yourself (see below), and run `megabox_server_creator.exe`.

**Android:** download `MegaBox.apk` from Releases, open it and allow installation from this source. If Google Play Protect shows a warning, choose "Install anyway". The APK is signed with the developer's key, not through Google Play. For diagnostics on a phone, turn the VPN off, otherwise the check will show the connection through the VPN rather than your own network.

## Step-by-step guide

1. **Prepare the VPS.** Use a clean Ubuntu or Debian server and note its IP, SSH port, user and password.
2. **Open the app** and fill in the form:

   | Field | What to enter |
   |-------|---------------|
   | VPS IP address | The server's public IPv4 |
   | SSH port | Default 22 |
   | User | `root` or a sudo user |
   | Password | The password for this user |
   | SNI | REALITY destination domain, e.g. `www.google.com` or `cloudflare.com` |
   | VLESS port | Default 443 |
   | Remark | Any name for your server list |

3. **Run the diagnostics** (the "Check" tab, or the "Check server before install" switch). If all checks are green, continue. If there are warnings, review the problem list first.
4. **Press "Deploy".** The app goes through the stages:
   - 1/6 system preparation (apt, BBR, freeing port 443)
   - 2/6 non-interactive 3X-UI installation
   - 3/6 key generation (x25519, UUID, shortId)
   - 4/6 creating the VLESS REALITY inbound via the API
   - 5/6 fetching the link
   - 6/6 done
5. **Copy the `vless://` link** or show the QR code and import it into your client.

## Clients

- **Android:** v2rayNG, V2FlyNG
- **iOS:** Shadowrocket, Stash
- **Windows and macOS:** v2rayN, Clash Verge
- **Linux:** Xray-core, v2ray-core

## Security

- Use the app only on a server you own, and follow the laws of your country and of the server's location.
- The 3X-UI panel is served over plain HTTP. Access it through an SSH tunnel or a reverse proxy with HTTPS.
- Panel login and password are generated randomly and shown in the log. Save them: they cannot be recovered after the app is closed.
- Saved server history stores links, panel credentials and SSH passwords in the app's local storage **without encryption**. Do not use the app on someone else's computer or keep the history on shared devices.
- The SSH server key is remembered on first connection (Trust On First Use). If it changes later, the app refuses to connect and does not send the password. After a legitimate VPS reinstall, reset the remembered key for that server in the app.

## Building from source

```bash
git clone https://github.com/<your-username>/megabox_server_creator.git
cd megabox_server_creator
flutter pub get

# Windows
flutter run -d windows
flutter build windows --release        # output: build\windows\x64\runner\Release\

# Android
flutter build apk --release --split-per-abi --target-platform android-arm64
```

On Windows, `build_android_auto.bat` is a convenient way to build the Android APK: it installs JDK, Android SDK and NDK into `C:\Android` and builds the APK. If your user path contains non-ASCII characters, the script moves the Pub cache and temp files to `C:\Android`, because CMake/Ninja can fail on such paths.

## Tests

```bash
flutter test
```

Tests cover the generated VPS scripts, parsing of diagnostics output, server history, SQL for the 3X-UI database and basic UI. Some tests use a local TCP socket and do not need a server.

## Project structure

```
lib/
├── main.dart                     # entry point, separate layouts for desktop and phone
├── screens/                      # home, servers, diagnostics
├── services/
│   ├── ssh_service.dart          # SSH installation and configuration
│   ├── diagnostics_service.dart  # pre-install checks
│   ├── api_service.dart          # 3X-UI API client
│   ├── server_management_service.dart
│   └── storage_service.dart      # local server history
├── models/                       # configuration and result models
├── widgets/                      # widgets, link cards, log
└── theme/                        # styling
android/                          # Android build
windows/                          # Windows build
tool/                             # Android build scripts for Windows
test/                             # tests
```

See [ARCHITECTURE.md](ARCHITECTURE.md) for more details.

## License

MIT, see [LICENSE](LICENSE).

## Acknowledgments

- [3X-UI](https://github.com/mhsanaei/3x-ui) — Xray panel
- [Xray-core](https://github.com/XTLS/Xray-core) — proxy core
- [Flutter](https://flutter.dev/) — UI framework
- [dartssh2](https://pub.dev/packages/dartssh2) — SSH client for Dart
