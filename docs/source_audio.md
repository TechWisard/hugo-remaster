# Исходные speaker actors и звуковые параметры

Модуль `tools/hugo_assets/speakers.py` дополняет gameplay decoder. Он не
запускает EXE и не меняет оригинальные файлы. Анализ выполнен на RU
`HUGO4.CD` с SHA-256
`fac39256dfdeedc4b19e07c171048e8c4e72a4fbe37cb4a8b8791239972aaa58`;
адреса относятся к `HUGO4_PC.EXE` с SHA-256
`bbd9c5a756ab63c1585284c63e5315b6ca1628b953d8f474f87d8f3a750b5cd3`.

Проверены все 862 CSound records, 71 CSpeaker и 46 CLoudSpeaker во всех
81 группах. В CLoudSpeaker найдено 90 cues. Четыре CLoudSpeaker принадлежат
неигровым сценам; в восьми игровых главах находятся 71 CSpeaker и
42 CLoudSpeaker. WAV bytes экспортирует существующий gameplay exporter;
новый модуль декодирует настройки и время воспроизведения.

## API и структура результата

`decode_sound_settings(record) -> dict` добавляется непосредственно в каждый
результат `GameplayDecoder.sound()`. Поэтому обычные звуки actor states,
pickups и speakers получают одни и те же поля `volume`, `flags`,
`range_coefficient`, `native_loop`, `spatial`, `custom_range`,
`suppress_same_group`, `exclusive_group`, `mix_group`, `attenuation`.

Flag `0x20` подавляет новый play только если уже играет другой sound с
**собственным flag `0x20`** и тем же `exclusive_group` (record `+0x24`,
младшие 16 бит). Это не `mix_group`: последний — независимый volume bus.
Проверки стоят в `0x418BCA..0x418C0A`.

`decode_speaker(record, decoder) -> dict` возвращает данные для `owner.update`:

```json
{
  "transform": {"reference": {}, "source_position": [], "position": []},
  "position": [0, 0, 0],
  "speaker": {
    "mode": "continuous",
    "transform_track": "g002_r0000",
    "repeat": true,
    "initial_enabled": true,
    "activation_event": 838860801,
    "sound": {"path": "audio/g001_r0007.wav", "volume": 0.8, "flags": 13}
  }
}
```

Это синтетический пример схемы. Для `mode: sequence` вместо `sound` имеются
`sound_sequence` с исходными cues, `period_seconds`, `initial_phase` и
политика выборки transform. Все пути относительны generated directory;
исходные абсолютные пути в JSON не записываются. Сами transform tracks уже
находятся в level manifest `native_transform_tracks`.

## CSpeaker, type 10500

Фабрика `0x40B200` вызывает constructor `0x404CB0`; RTTI и vtable `0x43E498`
подтверждают класс CSpeaker. Фиксированный record занимает 72 байта:

| Поле | Назначение |
| --- | --- |
| `+0x08` | Scoped reference на transform 3000–3003 |
| `+0x0C` | Scoped reference на CSound 1000 |
| `+0x10` | Повторять после окончания |
| `+0x14` | Исходное enabled |
| `+0x18` | Pending start; constructor устанавливает 1 |

Constructor получает **phase 0** transform и прикрепляет его к созданному
SoundInstance (`0x404D3D..0x404D48`). CSpeaker не семплирует transform на
каждом update. Handler `0x404E50` имеет следующую семантику:

- `0x32000001`: установить enabled и pending start. Текущее воспроизведение
  не прерывается.
- `0x22020003`: если enabled и звук не играет, pending start вызывает play
  и сбрасывается. В следующих циклах repeat вызывает play вновь; при
  отсутствии обоих флагов enabled сбрасывается.
- `0x22020005`: при активном звуке вызывается SoundInstance vtable+0x38.
  В этой Windows сборке метод равен `0x42DE00`, то есть no-op.

Все 71 исходных CSpeaker имеют enabled и repeat. Это не означает, что все
71 должны звучать сразу: жизненный цикл зависит от загрузки исходного
scope. Destructor `0x404DC0` освобождает/останавливает sound instance.

## CLoudSpeaker, type 10501

Constructor `0x406250`, handler `0x406460`, RTTI/vtable `0x43E564`.
Заголовок 152 байта, за ним последовательность cues по 84 байта.

| Поле | Назначение |
| --- | --- |
| `+0x08` | Scoped reference на transform |
| `+0x0C` | Период таймера в секундах |
| `+0x10` | Начало embedded CSoundSequence |
| `+0x14` | Знаменатель нормализации cue timestamps |
| `+0x20` | Packed cue count/owner-relative offset |
| `+0x34` | Начальная normalized phase таймера |

На каждом `0x22020003` таймер добавляет `delta_seconds / period`, затем
transform семплируется по полученной фазе. Источник использует loop mode 0.
`0x416100` выполняет wrap при **phase > 1**, а не при равенстве единице.
Исходные периоды находятся в диапазоне 2–109 секунд; начальная фаза всех
46 объектов равна 0.

CSoundSequence init `0x4158D0` разрешает owner-relative array, делит исходные
timestamps на знаменатель и создает отдельный SoundInstance на каждый cue.
Они привязаны к обновляемой матрице speaker. `0x4159F0` играет все cues,
достигнутые текущей normalized phase, по порядку. При wrap handler **после
этого** сбрасывает cursor через `0x415A50`. Звуки предыдущего цикла не
останавливаются только из-за wrap. Destructor останавливает все instances
через `0x415A60`.

У CLoudSpeaker handler нет отдельной команды включения. Начало обновлений
задается регистрацией объекта и жизненным циклом его scope. При реализации
современного streaming нельзя подменять это запуском таймера всей главы
при загрузке.

## CSound, type 1000

Record содержит 44 байта. Constructor `0x42CB40` устанавливает vtable,
`0x42CB50` создает CSoundInstance из полей record+4. Scoped WAV sample ID
из `+0x08` разрешает основной gameplay decoder. Значения ниже подтверждены
читателями CSFXManager и SoundInstance:

| Поле | Подтвержденное использование |
| --- | --- |
| `+0x04` | Flags |
| `+0x10` | Volume scalar |
| `+0x14` | Исходный pan; во всех records 0.5 |
| `+0x18` | Слово, читаемое sound instance как frequency; raw сохранен |
| `+0x1C` | Пользовательский коэффициент дальности |
| `+0x20` | Слово priority, сохранено без runtime применения |
| `+0x24` low16 | Group ID для подавления одновременного воспроизведения |
| `+0x26` uint16 | Индекс таблицы 64 mix gains |
| `+0x28` | Вычитаемая squared-distance величина при flag 0x40 |

Flags:

| Маска | Доказанный эффект |
| --- | --- |
| `0x01` | Loop в вызове sample playback (`0x418C9D`, `0x420A4B`) |
| `0x04` | Учитывать расстояние (`0x419228`) |
| `0x08` | Применять коэффициент дальности `+0x1C` (`0x4192C9`) |
| `0x20` | Не начинать звук, пока играет звук с собственным flag 0x20 и таким же exclusive group ID (`0x418BCA`) |
| `0x40` | Вычитать поле `+0x28` из scaled squared distance (`0x41929E`) |

Поле `+0x18` в исходных records имеет 0/1, значения, похожие на остаточные
байты, и нечисловые float bit patterns. Превращать его в pitch из файла
нельзя: нужная нормализация/инициализация пока не доказана. Экспорт сохраняет
его как `runtime_frequency_word_raw` integer, и JSON не содержит NaN.
Этот предел относится к исходной частоте, а не к доступности самих WAV.

## Точное расстояние и громкость

`0x419210` вычисляет source position difference, умноженную на `1e-4` через
`0x419460`. У exported positions масштаб `.01`, поэтому используемая
нормализованная дистанция равна `godot_distance * .01`.

В игровой сцене distance listener — **позиция Hugo**, а не камеры.
Hugo init `0x402247` сохраняет указатель `Hugo +0x44` (живой world position)
в EBX; `0x40234E..0x402353` передаёт его в CSFXManager vtable+0x4C.
Setter `0x418F50` записывает manager `+0x514`, который используется в
вычитании позиции source sound в `0x41925C..0x419267`.

Камера независимо задаёт **panning origin и axis**. CTargetCam constructor
`0x40A588..0x40A58E` передаёт `camera+0x6C` в setter `0x418F60` (manager
`+0x518`); `0x40A5AF..0x40A5B4` передаёт `camera+0x3C` в `0x418F70`
(manager `+0x510`). Panning branch использует эти поля начиная с `0x419313`.
Современный spatial pan может следовать viewport camera, но source gain
должен по-прежнему учитывать расстояние от Hugo.

Для spatial sound, положительного squared distance `d2` и
`k = .1 * (range_coefficient if flags & 8 else 1)`:

```text
if d2 > 10*k: scalar = 0
else: scalar = volume*k/(k+d2)
scalar *= master_gain * mix_gain
```

При `d2 <= 0` или без spatial flag применяется исходный volume. Flag 0x40
предварительно вычитает source поле `+0x28`; в проверенных source flags
этот бит не установлен. Native helper `native_volume_scalar` хранит именно
эти условия, а не подобранную inverse-distance кривую Godot.

Полученный scalar **не является линейной амплитудой**. Backend `0x4209E1`
и `0x420B86` переводит его в DirectSound hundredth-dB:

```text
scalar == 0: -10000
otherwise: trunc((scalar - 1) * 2500)
```

Для Godot это `-100 dB` при нуле либо `trunc((scalar-1)*2500)/100 dB`.
Например, scalar 0.5 дает -12.5 dB. Использование `linear_to_db` изменило
бы исходную кривую. `native_volume_db` — reference implementation для
runtime и тестов. Пространственные настройки всех активных channels
обновляет CSFXManager `0x419040`, независимо от пустого speaker render hook.

Точный итоговый pan, legacy channel arbitration при переполнении и
инициализация frequency пока не заявлены совпадающими с оригиналом.
Код сохраняет исходные flags и groups для последующей проверки.

## Проверки

`tests/test_speakers.py` использует синтетические records. Проверяются
ancestor references, включение без restart, phase-0 pose, разные timer и
cue denominators, cue bounds/order, неверные references, нечисловые
параметры и допустимое raw frequency слово с NaN bit pattern, отдельные
attenuation и dB формулы. На RU выполнен полный decode всех 117 speakers и
862 sound records с JSON `allow_nan=False`; ошибок и unresolved WAV refs
не найдено.
