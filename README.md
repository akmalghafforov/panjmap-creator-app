# Panjmap Android capture

Russian field capture MVP: sign in, choose a place type, photograph an entrance, obtain foreground GPS, review and submit. Android API 24+. New places only; one recoverable draft. Includes a display-only map and recent server-created objects; no citizen records, background location or background synchronization.

## Prerequisites and run

Install Flutter stable (developed with the installed SDK; see `flutter --version`), Android Studio / Android SDK, Java 17+, accept Android SDK licenses with `flutter doctor --android-licenses`, and check `flutter doctor`. The first build needs network access for Gradle, Maven and pub dependencies. Keep `pubspec.lock` in version control.

```sh
flutter pub get
flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8000/api/v1
flutter build apk --debug --dart-define=API_BASE_URL=http://10.0.2.2:8000/api/v1
```

`API_BASE_URL` is the full API root including `/api/v1`, without query or fragment. Android emulator reaches the host at `10.0.2.2`. A physical device needs the host LAN address and a reachable backend listening on `0.0.0.0`; alternatively `adb reverse tcp:8000 tcp:8000` and use `http://127.0.0.1:8000/api/v1`. HTTP is allowed only in debug. Release requires HTTPS and separately configured production signing; the generated release configuration currently uses a development signing key.

## Run on Medium_Phone

Create an Android Studio virtual device named `Medium_Phone` once, then run:

```sh
make run
```

This starts the emulator if necessary, waits for Android to boot, and runs Flutter on that specific device. An already running `Medium_Phone` is reused. Keep the backend and queue worker running separately. The default API root is `http://10.0.2.2:8000/api/v1`.

Override configuration when needed:

```sh
make run API_BASE_URL=https://your-server.example/api/v1
make run AVD=Another_Device
```

The helper uses `ANDROID_HOME`, then `ANDROID_SDK_ROOT`, then `android/local.properties`, falling back to `~/Android/Sdk`. Flutter must be on PATH, or pass `FLUTTER=/path/to/flutter`. Requires Bash and GNU `timeout` (available on Ubuntu). Emulator startup logs are stored in `~/.cache/panjmap-capture/emulator.log` (or under `XDG_CACHE_HOME`).

## Backend deployment prerequisites

Companion changes are in `../panjmap`. Deploy them before using this client:

1. Coordinate this breaking update with the backend: back up the database and pause API writes and workers before deployment. Run `php artisan migrate --force` as the migration owner. The `2026_10_18_000002_remove_collection_areas.php` migration irreversibly removes collection areas and assignments; recovery requires the pre-upgrade backup. Update the mobile client, smoke-test login, address lookup, photo/GPS, submission, recent objects and restart/retry, then resume service. Access is shared according to active-account, role, capability and token checks; recent objects remain creator-only. Incremental migration `2026_10_17_000001_extend_capture_contract.php` adds `shop`, `building`, `other` to the place check and prevents residence links to them. Existing residential types retain their rules. Rolling back requires removing/reclassifying new-type records first.
2. Deploy the optional photo upload `id` field and UUID advisory locking. Old clients may omit `id`. Reusing an accepted UUID with another logical request returns 409 before storage writes. The transaction lock covers the outer idempotency receipt commit.
3. Configure private photo storage and run `php artisan queue:work`. Upload confirmation and processing completion are separate; the worker must be running for processing to finish.

For disposable local development only:

```sh
cd ../panjmap
docker compose up -d --wait
# Configure .env using this repository's .env.example and README.
php artisan migrate
php artisan db:seed
php artisan serve --host=0.0.0.0 --port=8000
# In another terminal:
php artisan queue:work
```

The backend seeder provides `mapper@example.test`, `collector@example.test`, and `reviewer@example.test`, password `synthetic-test-password`. Use synthetic data only. Administrator accounts do not have field collection capability. Do not seed these accounts in production.

## Recovery and operations

Tokens use Android secure storage. Capture bytes and atomically replaced draft JSON live in app-private support storage. Android backup is disabled. Camera activity destruction is handled at startup using `retrieveLostData`; the image is copied before being shown as saved, following the [image_picker lifecycle guidance](https://pub.dev/packages/image_picker). GPS uses [geolocator foreground requests](https://pub.dev/packages/geolocator).

Capture failures preserve the last successful photo/fix. Before first submission, GPS must be at most two minutes old; accuracy over 30 m or approximate permission shows a warning. Photos are requested at 2048×2048, quality 85, then checked for JPEG/PNG/WebP, actual dimensions and configured server limits.

Submission freezes payloads and UUIDs before any request. Separate persistent idempotency keys are used for place, entrance and photo. A single controller operation prevents double taps. On explicit retry, GET by each UUID reconciles relationships and metadata before creating anything. Reauthentication must use the original account and API origin. Completed partial records stay on the server; there are no rollback requests. The photo file hash is checked before an upload retry. Do not clear app data or uninstall to recover a failed submission; provide the displayed UUIDs to an administrator.

Sending all bytes shows “awaiting confirmation”, not success. A confirmed upload is retained until “start next record”. Processing is polled every two seconds for up to 30 seconds; pending processing can be checked again. Failed processing requires operator attention and never automatically creates another photo.

## Verification

```sh
flutter analyze
flutter test
flutter build apk --debug --dart-define=API_BASE_URL=http://10.0.2.2:8000/api/v1
cd ../panjmap
php artisan test
python3 docs/validate_contract.py </dev/null
```

Backend suite passes: 36 tests, 423 assertions, including nonresidential rules, legacy photo upload, UUID conflict preservation and actual simultaneous photo uploads with different idempotency keys. OpenAPI schemas/references validate. App checks cover cancellation, GPS failure, stale fix, storage failure, double taps, account isolation, restart/lost response reconciliation, inconsistent records and HTTP/multipart contract. Final Flutter/build results are recorded below after execution.

Manual device checks remain: camera refusal/permanent denial and missing camera app, Android activity destruction during capture, approximate permissions, disabled GPS and 30-second timeout, fresh GPS outdoors, airplane-mode interruption at each write and upload confirmation, expired session/relogin, processing failure, process termination/relaunch, and next-record retention. No Android device was attached during implementation.

Environment used: Flutter 3.47.3 stable, Dart 3.13.3. Production signing and a physical-device smoke test are deployment tasks.

Final results (2026-10-17): `flutter analyze` reports no issues; all 11 Flutter tests pass. Backend: all 36 tests pass (423 assertions); PHP syntax and OpenAPI contract checks pass. `flutter build apk --debug` was attempted but did not reach compilation: the Gradle 9.3.1 distribution download remained incomplete and a duplicate attempt timed out waiting 120 seconds for its download lock. The stalled attempts were stopped; no APK is claimed. Retry the documented build on a working toolchain/network. `adb devices` returned no attached devices, so no hardware smoke test was performed. The isolated `panjmap-postgres-1` development test container was started for verification and remains running.

## Проверка адреса

После получения координат входа приложение запрашивает `GET /geography/suggestions` для назначенного участка. При точном GPS (до 30 м) однозначная махалля и ближайшая улица заполняются автоматически и помечаются в карточках. При обновлении координат или участка автоматические значения обновляются; ручные названия, выбор из справочника и намеренно пустые поля сохраняются. Другую надёжную подсказку можно принять через «Заменить» с подтверждением текущего и нового названия. Названия можно исправить или очистить; оба поля необязательны. При неоднозначности или ошибке автоматические поля остаются пустыми, доступен ручной ввод и повтор подсказок. После восстановления незавершённого черновика подсказки запрашиваются снова; подготовленная к отправке запись не меняется.

Выбор сохраняется в восстанавливаемом черновике вместе с участком и включается в неизменяемый запрос объекта при отправке. Повторная отправка и ранее частично отправленные черновики продолжают использовать исходный payload. Исправления относятся только к собранному объекту и не переименовывают справочник.

Для работы нужны новые backend-маршруты `/api/v1/geography`, миграция географических таблиц и обновлённые runtime grants. Сначала разверните backend и ресурсы администратора, затем обновите приложение. `test/geography_test.dart` проверяет состояния выбора, восстановление, обновление GPS, устаревшие ответы и работу при ошибках подсказок.


После входа или восстановления сессии открывается карта Пенджикента (39.495, 67.61).
Геолокация запрашивается асинхронно; успешный запрос показывает текущую позицию.
Кнопка «Добавить новый объект» справа внизу открывает форму или текущий черновик.
Назад возвращает на карту, сохраняя введённые значения и состояние отправки.
В форме карта закреплена над прокручиваемыми полями. Координаты карты служат
только для отображения: для отправки по-прежнему требуется «Получить свежие координаты».
При недоступном GPS карта возвращается к Пенджикенту с пояснением и настройками.
Карта использует HTTPS-тайлы OpenStreetMap, видимую атрибуцию и встроенный HTTP-кэш
flutter_map (без предзагрузки и массового скачивания); доступность тайлов не гарантируется.


## Недавно добавленные объекты

На главном экране карта занимает ровно половину доступной высоты под панелью приложения.
Кнопка добавления находится внутри карты, в 16 px от нижнего правого угла; атрибуция остаётся видимой.
Нижняя половина прокручивается отдельно: последние 20 объектов текущего пользователя,
название (или тип), доступный адрес и время создания в часовом поясе устройства.
Список доступен при ошибках GPS и тайлов. Строки доступны только для чтения.

История загружается с сервера после входа/восстановления сессии, при возврате из формы,
после подтверждения создания объекта (включая восстановление по UUID) и по кнопке обновления.
Ошибки обновления сохраняют ранее загруженные строки. Черновики в список не входят;
наличие объекта в истории не означает завершение загрузки входа или фото.
При смене сессии история очищается; ответы предыдущей сессии игнорируются.

Сначала разверните companion backend с `GET /api/v1/places/recent?limit=20`, затем приложение.
Endpoint возвращает существующие place resources в `data`, только созданные текущим
пользователем в доступных назначенных участках, по `created_at DESC, id DESC`.
`limit`: 1–100, по умолчанию 20; без пагинации и новых миграций.

Legacy drafts lose obsolete area metadata before use. If normalization changes a frozen place payload, its replacement idempotency key is saved before network activity. Record UUIDs are retained and reconciled before writes.
