# Сборка iOS

Проект `SelBrowser.xcodeproj`, общая схема **SelBrowser**, минимальная версия **iOS 16**. Используется UIKit и WebKit. Исходники в `SelBrowser/Sources` и ресурсы в `SelBrowser/Resources` включаются автоматически через синхронизируемые группы Xcode 16+.

Для обновления **1.1.0 (2)** сохранён `com.selbrowser.ios`; это идентификатор той же установленной программы. Не меняйте идентификатор или Apple Account между установками, если требуется обновление существующего браузера с его данными.

## Подтверждённая сборка 1.1

[GitHub Actions run 40193192544](https://github.com/nqAI-ship-it/SelBrowser/actions/runs/40193192544), коммит `74aecf8b82fdefba9c02b204df5ca2a1aa972ea4`, успешно завершил весь workflow. Готова **SelBrowser-1.1.0-unsigned.ipa**: Xcode **26.3**, device SDK **26.2.0**, ARM64 для iPhone, минимальная iOS **16.0**, версия **1.1.0 (2)**. Размер, SHA-256 и проверки содержимого указаны в [VERIFICATION.md](VERIFICATION.md).

В том же запуске получены три smoke-отчёта по **15/15** успешных проверок и **18 PNG**. Проверены ветка настоящего Glass на runtime iOS **26+** и совместимый материал на runtime **ниже 26**; точные версии runtime не выведены. Физическое обновление 1.1 через iLoader ещё не проверено.

## GitHub Actions

Windows не компилирует iOS-приложение. Облачный workflow запускает Xcode 26.3 на `macos-15` и отклоняет SDK ниже iOS 26. Пакет поддерживает три расположения исходников: в корне репозитория, в `ios/` и в `Sel-iOS-source/`. Файл запуска должен находиться по пути `.github/workflows/ios-build.yml` от корня репозитория.

Уже настроенный репозиторий: [nqAI-ship-it/SelBrowser](https://github.com/nqAI-ship-it/SelBrowser). В нём исходники находятся в `Sel-iOS-source/`, а workflow — в корневой `.github`. При последующих загрузках сохраняйте это расположение, чтобы обновлять существующий проект.

Сборка запускается при изменении исходников, проекта или скриптов. Ручной запуск: **Actions → Build iOS → Run workflow**.

Workflow:

1. Проверяет комплектность проекта и JavaScript.
2. Компилирует Debug для iOS Simulator.
3. Запускает Debug-приложение на симуляторах iPhone и iPad и снимает экраны главной страницы, вкладок и настроек.
4. Компилирует Release для iPhone и упаковывает неподписанную IPA.
5. Сохраняет артефакты **SelBrowser-unsigned-IPA**, **SelBrowser-iOS-previews** и **SelBrowser-build-logs** на семь дней.

Снимки относятся к реально запущенному приложению в симуляторе. Они не заменяют проверку на физическом устройстве. Режим `--sel-ui-preview home|tabs|tabs-search|settings|search|home-dark` существует только в Debug; тестовые вкладки локальные и не обращаются к сайтам. Системная подсказка QuickPath первого запуска может перекрывать часть клавиатуры на кадре `tabs-search`; это ограничение снимка.

Сборка использует стандартный runner в публичном репозитории. Workflow намеренно пропускает приватные репозитории, чтобы не расходовать потенциально платные macOS-минуты. Исходники публичного репозитория общедоступны. [Правила GitHub](https://docs.github.com/en/actions/reference/runners/github-hosted-runners).

Apple Account, пароль, сертификаты и токены App Store Connect workflow не нужны. Результат подписывается локально через iLoader собственным аккаунтом; [инструкция](INSTALL-WINDOWS.md).

## macOS

```sh
bash scripts/build-ios.sh --simulator-only
bash scripts/capture-ios-previews.sh
bash scripts/build-ios.sh
```

Для снимков нужен установленный iOS Simulator runtime. Пакет создаётся в `dist/SelBrowser-unsigned.ipa`. В указанном выше запуске компиляция Swift подтверждена; после следующих изменений требуется новый успешный запуск. Файл исходников или старый IPA сам по себе не подтверждает сборку новой ревизии.
