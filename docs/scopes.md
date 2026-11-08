# Исходная загрузка участков и включение объектов

`tools/hugo_assets/scopes.py` восстанавливает данные исходного loader и
`CActorManager`. `levels.py` добавляет результат в `native_scope_policy`
каждого level manifest. EXE анализировался только статически.

Проверенный RU `HUGO4.CD`:
`fac39256dfdeedc4b19e07c171048e8c4e72a4fbe37cb4a8b8791239972aaa58`.
Адреса ниже относятся к `HUGO4_PC.EXE`:
`bbd9c5a756ab63c1585284c63e5315b6ca1628b953d8f474f87d8f3a750b5cd3`.

## Что действительно загружается

`CSceneScope::0x42FB20` возвращает **2** как максимальное число дочерних
segment scopes. Main scope и global scope существуют отдельно. На старте
`CSceneScopeProxy::0x42DD40` запрашивает только первый дочерний segment,
указанный в header `+0x18`. Main и первый segment получают событие activation
вместе после построения ресурсов. Если дочерних участков нет, ожидать нечего.

`CScopeManager::0x41B650` получает параметры `(category, file, offset, parent)`.
Категория 4 означает создание `CSegmentScopeProxy`; это не номер команды
«активировать участок». Если такой offset уже есть среди дочерних scopes
и он не выгружается, новый запрос ничего не создаёт.

`CSceneScopeProxy::0x42DB70` проверяет действующее окно по абсолютным offsets
в контейнере. Когда в окне уже два участка:

- новый offset меньше обоих: выгружается участок с большим offset;
- новый offset больше обоих: выгружается участок с меньшим offset;
- повтор уже имеющегося offset ничего не меняет.

Таким образом, из `[i, i+1]` при запросе `i+2` получается `[i+1, i+2]`.
При запросе `i-1` получается `[i-1, i]`. Это сравнение offsets, а не расстояния
до spatial bounds. В нормальном исходном пути запросы приходят только через
соседние ссылки. Произвольный запрос между двумя несмежными resident offsets
не поддержан: native ветка `0x42DCF7` не выбирает валидный объект для eviction.

Новый child proxy сначала находится в состоянии 0. Цикл `0x42D8DB..0x42D923`
начинает его загрузку лишь после того, как осталось меньше двух дочерних
proxies с ненулевым состоянием. Выгружаемый child тоже занимает место, пока
освобождение не завершено. После создания ресурсов child получает state 2
и рассылает scope activation. Отдельного режима «сосед только рисуется,
его логика не идёт» в этом пути нет: оба активированных resident scopes
могут обновляться и рисоваться с учётом индивидуальных actor gates.

### Проверенные поля main scope

Category-3 header занимает 288 байт. Category-4 header — 24 байта.

| Поле category 3 | Значение |
| --- | --- |
| `+0x14` | Размер общего буфера для двух соседних child payloads |
| `+0x18` | Абсолютный offset первого child MDIC group; 0, если children нет |
| `+0x1C` | Число child scopes, максимум 32 |
| `+0x20` | Таблица 32 размеров: payload + 16 байт chunk header |
| `+0xA0` | Таблица 32 абсолютных offsets child MDIC groups |

Category-4 `+0x10` и `+0x14` содержат предыдущий и следующий group offsets;
0 обозначает отсутствие соседа. Getter'ы `CSegmentScope::0x42BD90` и
`0x42D3D0`, а также вызовы из `CSegmentTrigger`, подтверждают направление.

`0x42DD00..0x42DD28` выбирает место в общем буфере по чётности child ordinal:
чётный ordinal использует начало, нечётный — `buffer_end - payload_size`.
Decoder проверяет обе таблицы, соответствие MDIC groups и отсутствие
перекрытия буферов для любой соседней пары. Неиспользованные слова header
не получают придуманного назначения.

## Плоскости переключения используют камеру

Type 10600 — `CSegmentTrigger`, fixed record 96 байт, transform ref `+0x0C`.
Все 54 исходных transform refs этого класса ведут к статическим type-3000
матрицам. Новая animated plane явно отклоняется decoder, пока её поддержка
не проверена.

Constructor `0x407644..0x407669` получает текущую **I3DCamera** через
renderer interface `0x11060002`, vtable `+0x44`. Это тот же интерфейс, который
использует `CBackmap::0x40575E..0x405766`. В handler `0x407771..0x407776`
метод камеры `+0x30 = 0x422500` возвращает её world transform.

На событии `0x22020004`, если собственный scope находится в state 2:

```text
axis = trigger.matrix.column(1)
distance_sign = dot(camera.position - trigger.position, axis)
requested = previous_group if distance_sign < 0 else next_group
```

Нулевой target не запрашивается. Ровно на плоскости выбирается следующий
участок. `0x40BDB0` с index 1 выбирает native matrix column 1; это не строка
и не вычисленная inverse-transpose normal. Decoder сохраняет её длину.

В этом handler **нет AABB-проверки**. Сериализованные bbox поля trigger
сами по себе не означают, что камера или Hugo должны входить в Area3D.
Проверка плоскости выполняется для каждого зарегистрированного resident
trigger на phase-2 update. Выбор по позиции Hugo или входу в trigger box
изменил бы исходный момент загрузки.

JSON хранит origin в Godot units `(x,z,-y)*.01`, normal — в осях `(x,z,-y)`
без изменения масштаба. В `source_origin` и `source_normal` остаются исходные
векторы; evidence содержит group, record, scene/container offsets и VA.

## Scope activation и индивидуальные actor ranges

RTTI подтверждает `CActorManager`, vtable `0x43F144`.
При регистрации `0x41C0C0` он сохраняет исходные update flags и обнуляет
действующие flags для scoped actors. Scope activation `0x22010100`
(`0x41BDD4`) восстанавливает flags для actor IDs с совпадающим старшим
16-битным scope serial. Scope deactivation `0x22010101` (`0x41BE77`)
обнуляет их снова. Сохранённый serial равен `group + 1`.

Независимо от residency, manager применяет включающий обе границы диапазон
из embedded `CActorClientInfo +0x20/+0x24`. Текущий progress:

```text
progress = trunc(camera.CSnapTracker.phase * 992.0)
active = minimum <= progress <= maximum
```

Источник формулы — `CTargetCam::0x40A8C5..0x40A901`. Float32 по адресу
`0x43E6D8` равен **992.0**, а не 1000. `0x41C3A0` сохраняет progress в
manager `+0x9B0`. Native camera обновляет этот параметр на своём phase-2
проходе; timing между phase-1/phase-2 следует учитывать при runtime tests.

| Класс | Авторские minimum / maximum в record | Доказательство constructor |
| --- | --- | --- |
| 10300 `CSimpleStateActor` | `+0xDC / +0xE0` | `0x40788A..0x4078A9` |
| 10301 `CPowerUp` | `+0x8C / +0x90` | `0x406FF2..0x40700E` |
| 10401 `COrnemental` | `+0x90 / +0x94` | `0x406850` |
| 10400 `CDefaultSegment` | `+0x90 / +0x94` | `0x40598C` вызывает Ornemental constructor |
| 10402 `CPlatform` | `+0x90 / +0x94` | `0x406C3E` вызывает `0x4067B0` |

Hugo, CTargetCam, CActorTrigger, CBackmap, CSpeaker, CLoudSpeaker,
CSegmentTrigger и CEndOfLevelTrigger constructors заменяют эти поля на
`0..1000`. NotifyTrigger и FallTrigger не регистрируются в ActorManager;
их жизненный цикл связан с residency и native collision system.

Два реальных Platform records в главе main group 46 имеют `555..550`.
Decoder сохраняет порядок и ставит `never_in_range: true`; сортировка границ
включила бы объекты, которые native условие никогда не включает.

Первый вход в range вызывает `0x22020000` и `0x22020002`, выход —
`0x22020001`, повторный вход — `0x22020002` без повторной first-init.
Действующие flags определяют три прохода:

| Flag | Событие | Native dispatch |
| --- | --- | --- |
| 1 | `0x22020003` | `0x41BD09..0x41BD3A` |
| 2 | `0x22020004` | `0x41BD66..0x41BD96` |
| 4 | `0x22020005` | `0x41BD98..0x41BDCB` |

Выход из actor range и полная выгрузка scope — разные операции. Выгрузка
уничтожает ресурсы/actors; новый вход в такой scope заново создаёт их из
исходных данных. При этом ActorManager учитывает сохранённые ID удалённых
actors. Конкретные state timers, события deactivate/activate и checkpoint
payload принадлежат соответствующим actor classes.

## Checkpoint и возврат

ScopeManager обрабатывает save `0x22000030` и restore `0x22000031`
в `0x41B330`. Scene proxy на save `0x22010200` (`0x42DAF2`) сохраняет
offsets всех children, чьё состояние не 3/4, максимум двух. Это включает
уже запрошенный/loading child, а не только полностью constructed child.

На restore `0x22010201` (`0x42DA69`):

1. Все текущие child scopes запрашиваются на выгрузку.
2. Каждый сохранённый child offset запрашивается заново.
3. Main scope сбрасывает activation и возвращается в начальное ожидание;
   actor updates приостановлены.
4. После создания сохранённых scopes восстанавливаются activation flags и
   actor checkpoint payloads (`0x41BF1B`).

Начальный checkpoint создаётся после первого успешного старта main + first
segment. Нативный restore не оставляет одновременно все сегменты главы
живыми. Модуль экспортирует protocol metadata; actor-specific snapshots
декодирует gameplay module.

## API и проверки

```python
policy = decode_scope_policy(catalog, main_group)
target = choose_neighbor(policy["triggers"][0], camera_position)
plan = plan_scope_request(policy, resident_groups, target)  # target is not None
enabled = actor_in_range(policy["actor_ranges"][owner_id], camera_phase)
```

`plan_scope_request` возвращает `unload_groups`, `load_groups`,
`resident_after`: это итог завершённой операции, а не имитация скорости CD.
Все source paths в manifest относительны; функции ничего не загружают и
не запускают.

Проверка RU и PT охватывает по 18 main scopes, 62 child scopes и 54 trigger
planes. Во всех восьми игровых главах положения/оси planes и actor ranges
совпадают между языковыми версиями; контейнерные offsets проверяются отдельно.
В восьми игровых главах — 60 children и 2428 actor range entries:

| Main group | Children | Plane triggers | Actor ranges | Начальный child |
| --- | ---: | ---: | ---: | ---: |
| 6 | 10 | 9 | 410 | 7 |
| 17 | 8 | 7 | 277 | 18 |
| 27 | 8 | 7 | 367 | 28 |
| 36 | 8 | 7 | 334 | 37 |
| 46 | 7 | 7 | 368 | 47 |
| 55 | 3 | 2 | 165 | 56 |
| 59 | 8 | 7 | 304 | 60 |
| 69 | 8 | 8 | 203 | 70 |

Семь synthetic tests проверяют таблицы и buffer overlap, направление и
границу plane test, возврат и eviction окна, range 992/inclusive boundaries,
намеренно пустой диапазон, повреждённые refs/headers и нечисловые позиции.
Экспорт level отдельно проверяет присутствие policy в JSON.

Оставшаяся граница: по данным ресурса нельзя воспроизвести точную задержку
асинхронного чтения CD, очереди создания/уничтожения ресурсов и гонку
нескольких запросов в одном update. Runtime может заранее держать meshes
в памяти, но должен отдельно соблюдать source scope activation, range
gates и reset/reconstruction semantics. Сами эти данные проверены без
исполнения оригинального EXE.
