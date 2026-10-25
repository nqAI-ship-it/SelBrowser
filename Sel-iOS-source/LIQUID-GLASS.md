# Sel для iOS 1.1.0 (2)

Обновление объединяет нижнюю навигацию и отдельный экран вкладок по образцу приложения Google для iOS с официальным Apple Liquid Glass. Бренд и главная страница остаются Sel. Windows-версия не изменяется.

## Нативные элементы и веб-содержимое

| Элемент | Реализация |
| --- | --- |
| Плавающая адресная строка | UIKit, `UIGlassEffect(.regular)`, `UIVisualEffectView`, системная капсула, HTTPS-индикатор, анимация ввода |
| Нижняя панель | Одна стеклянная капсула: назад, вперёд, обновить/остановить, счётчик вкладок, меню |
| Кнопка настроек | Системный стиль `UIButton.Configuration.glass()` |
| Экран вкладок | Отдельный нативный экран; сетка превью, иконки сайтов, поиск, приватные вкладки, независимые крестики, перетаскивание |
| Управление экраном вкладок | Системные `glass()` / `prominentGlass()` в `UIGlassContainerEffect`; карточки страниц не покрываются стеклом |
| Настройки | `UINavigationController` и `UITableViewController` с поиском, переключателями и экранами выбора; системный вид нового SDK |
| Меню | Нативные `UIMenu`, `UIAction` и системные диалоги |
| Главная страница Sel | Прежний локальный HTML в изолированном WKWebView; верхние настольные панели скрыты на iPhone и iPad |
| Посещаемые сайты | Отдельные настоящие WKWebView в мобильном режиме; оформление сайтов не изменяется |

Glass находится в навигационном слое поверх сайта. `UIScrollEdgeElementContainerInteraction` поддерживает контраст у краёв прокрутки. Контейнеры объединяют соседние эффекты; стеклянные слои не накладываются друг на друга. Системные цвета адаптируются к светлой/тёмной теме и контрастности. Уменьшение прозрачности переключает пользовательские панели на непрозрачный системный фон, уменьшение движения отключает собственную анимацию изменения адресной строки. Нижняя панель учитывает Safe Area и клавиатуру через `keyboardLayoutGuide`.

## Совместимость и данные

- iOS/iPadOS 26+ используют настоящий `UIGlassEffect`.
- iOS/iPadOS 16–25 используют `UIBlurEffect` и совместимые стандартные кнопки; обращения к новым API защищены `#available`.
- `com.selbrowser.ios` не меняется. JSON-профиль, каталог закладок/настроек, сессия и папка загрузок остаются прежними.
- Миниатюры существуют только в памяти, включая приватный режим, и освобождаются при предупреждении о памяти.
- Обновлять IPA нужно поверх установленной версии через iLoader тем же Apple Account. Предварительное удаление браузера стирает его локальные данные.

## Сборка и проверка

GitHub Actions использует публичный `macos-15` и явно выбирает Xcode 26.3. Скрипт отклоняет SDK ниже iOS 26. Apple Account, сертификаты и provisioning profiles не передаются в GitHub; результат — unsigned IPA для локальной подписи.

Локально проверяются структура пакета, схема Xcode, plist, ресурсы и контракт безопасного JavaScript-моста. В CI выполняются компиляция Debug для симулятора, проверки закрытия средней/правой вкладки, сохранения выбранной вкладки, приватности, чтения профиля 1.0, нативного открытия вкладок/настроек и типа материала; затем снимаются экраны iPhone/iPad. При наличии старого runtime дополнительно проверяется интерфейс ниже iOS 26. Release компилируется для настоящего iPhone и упаковывается в IPA. Итоговый статус CI и хеш указываются в `VERIFICATION.md` после завершения сборки.

Версия 1.0 установлена через iLoader и, по сообщению пользователя, работает на его iPhone. Обновление 1.1 пока готовится; его компиляция и установка не объявляются проверенными до фактического результата.

## Изменённые файлы

- `SelBrowser/Sources/BrowserGlass.swift` — материал, контейнеры, совместимость и доступность.
- `SelBrowser/Sources/MobileBrowserChrome.swift` — адресная строка и нижняя навигация.
- `SelBrowser/Sources/TabOverviewController.swift` — отдельная библиотека вкладок.
- `SelBrowser/Sources/MobileSettingsController.swift` — нативные настройки.
- `SelBrowser/Sources/BrowserViewController.swift` — связывание интерфейса с WebKit, снимки, меню, проверки симулятора.
- `SelBrowser/Sources/BrowserModels.swift` — временные миниатюры и согласование тем без изменения сохраняемой схемы.
- `SelBrowser/Resources/Shell.html` — скрытие настольных панелей только в iOS-ресурсе.
- `SelBrowser.xcodeproj/project.pbxproj` — версия 1.1.0, сборка 2, тот же Bundle ID.
- `scripts/build-ios.sh` — проверка современного SDK и создание IPA.
- `scripts/capture-ios-previews.sh` — запуск и проверка интерфейса в симуляторах.
- `scripts/validate-package.py` — проверка обязательных ресурсов пакета.
- `.github/workflows/ios-build.yml` — Xcode 26.3, компиляция и артефакты проверки.
- `README.md`, `README-BUILD.md`, `INSTALL-WINDOWS.md`, `VERIFICATION.md`, `LIQUID-GLASS.md` — сведения об обновлении и установке.
- В Windows-папке: `prepare-ios.ps1`, `IOS.md` — подготовка iOS-ресурсов и инструкции; исходники Windows-интерфейса и `Sel.exe` не меняются.

## Использованные официальные руководства

- [Apple: Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)
- [Apple: Applying Liquid Glass to custom views](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views)
- [UIKit: UIGlassEffect](https://developer.apple.com/documentation/uikit/uiglasseffect)
- [UIKit: UIScrollEdgeElementContainerInteraction](https://developer.apple.com/documentation/uikit/uiscrolledgeelementcontainerinteraction)

SwiftUI-руководство описывает принципы материалов, группирования и анимации. Проект использует соответствующие публичные API UIKit, поэтому повторная параллельная реализация оболочки на SwiftUI не нужна.
