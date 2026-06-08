# engine/routing/tests — юнит-тесты генератора маршрутизации

Чистая логика → тесты гоняются за секунды, без роутера:

```sh
make test-engine                              # все тесты движка
ucode -R engine/routing/tests/test_routing.uc # только этот файл
```

Покрыто: нормализация/валидация доменов (LDH/punycode), отбрасывание мусора в `rejected`
(fail-safe), дедуп, все три рендера в режимах home/travel × ipv6 on/off × hook
prerouting/output, проброс кастомных mark/table/set.

End-to-end (реальный вывод генератора разводит трафик в network namespace) — это **фаза B**
в [tests/poc/split-routing-netns.sh](../../../tests/poc/split-routing-netns.sh), `make poc-split`.

## Нужен ucode

Тесты требуют интерпретатор `ucode`. На OpenWrt он штатный; на dev-хосте/в CI — нет
готового пакета, собирается из исходников. Рецепт без root (в userspace, проверен на
Ubuntu 24.04):

```sh
pip install --user --break-system-packages cmake          # cmake без root
PREFIX="$HOME/.local"

# json-c (зависимость ucode)
git clone --depth 1 https://github.com/json-c/json-c && cd json-c && mkdir build && cd build
cmake -DCMAKE_INSTALL_PREFIX="$PREFIX" -DBUILD_SHARED_LIBS=ON \
      -DCMAKE_C_FLAGS="-Wno-error" .. && make -j"$(nproc)" install && cd ../..

# ucode (нужен pkg-config для поиска json-c — на чистом хосте подойдёт shim/системный)
git clone --depth 1 https://github.com/jow-/ucode && cd ucode && mkdir build && cd build
cmake -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_PREFIX_PATH="$PREFIX" \
      -DUBUS_SUPPORT=OFF -DUCI_SUPPORT=OFF -DRTNL_SUPPORT=OFF -DNL80211_SUPPORT=OFF \
      -DCMAKE_C_FLAGS="-Wno-error" .. && make -j"$(nproc)" install && cd ../..

export PATH="$PREFIX/bin:$PATH"   # ucode -R -e 'print("ok\n")'
```

Сборка ucode с `UCI_SUPPORT`/`UBUS_SUPPORT` для host-тестов **не нужна** (тесты — чистая
логика). Когда движок начнёт звать нативные `uci`/`ubus`, такие тесты переедут на mock-слой
или в QEMU (см. пирамиду тестов в [reliability](../../../docs/v2/architecture/reliability.md)).

## Статус в CI

Юнит-тесты движка пока **не подключены** к `.github/workflows` — это часть фазы
«пакет + feed + CI» ([architecture-v2.md](../../../docs/architecture-v2.md#-план-миграции-strangler-fig-без-big-bang-rewrite),
фаза 2/6), где появится сборка через OpenWrt SDK и матрица QEMU. До тех пор тесты
запускаются локально через `make test-engine`. Это осознанная граница, а не пропуск.
