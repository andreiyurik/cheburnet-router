# lib/family-filter.sh — управление «Семейным режимом».
#
# Один тумблер, две подсистемы:
#
# 1. NSFW DNS-блок — Hagezi NSFW-лист (~95 600 доменов взрослого контента),
#    добавляется raw URL'ом к raw_block_lists в /etc/adblock-lean/config.
#    В сами тиры (light/normal/pro/...) Hagezi'ем NSFW не включён, поэтому
#    идёт отдельным URL, а не shortcut'ом hagezi:nsfw.
#
# 2. Force SafeSearch — CNAME-перенаправления через UCI list cname в
#    dhcp.@dnsmasq[0]. Поисковики и YouTube переадресуются на их же
#    SafeSearch-endpoint'ы (Google → forcesafesearch.google.com и т.д.).
#    UCI add_list/del_list работают по точному значению — мы не трогаем
#    cname от других подсистем.
#
# Source-only: ничего не выполняет, только определяет функции. Демоны сами
# не перезапускают — это ответственность вызывающего (rpcd-cheburnet делает
# adblock-lean start + dnsmasq restart в фоне после правки).
#
# Подключение:
#   . /opt/cheburnet/lib/family-filter.sh
#   family_filter_status   # печатает true | false (true ⟺ обе подсистемы включены)
#   family_filter_on       # idempotent
#   family_filter_off      # idempotent
#
# Путь конфига adblock можно переопределить через ENV ETC_ADBLOCK_CFG (для тестов).

FAMILY_FILTER_URL="https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/nsfw-onlydomains.txt"

# Force SafeSearch CNAME-список — стандартный набор, используемый Pi-hole / AGH.
# Каждая строка: src,dst — формат UCI list cname для dhcp.@dnsmasq[0].
# YouTube — strict-режим (restrict.youtube.com); если нужен moderate,
# заменить на restrictmoderate.youtube.com здесь и пере-включить тумблер.
SAFESEARCH_CNAMES="
www.google.com,forcesafesearch.google.com
google.com,forcesafesearch.google.com
www.youtube.com,restrict.youtube.com
m.youtube.com,restrict.youtube.com
youtubei.googleapis.com,restrict.youtube.com
youtube.googleapis.com,restrict.youtube.com
www.bing.com,strict.bing.com
bing.com,strict.bing.com
duckduckgo.com,safe.duckduckgo.com
www.duckduckgo.com,safe.duckduckgo.com
yandex.ru,familysearch.yandex.ru
www.yandex.ru,familysearch.yandex.ru
yandex.com,familysearch.yandex.ru
"

# Sentinel: по этому одному cname определяем, включён ли SafeSearch.
# Достаточно одного — мы добавляем и удаляем весь набор атомарно.
_SAFESEARCH_SENTINEL="www.google.com,forcesafesearch.google.com"

_family_filter_cfg() {
    printf '%s' "${ETC_ADBLOCK_CFG:-/etc/adblock-lean/config}"
}

# Возвращает текущее значение raw_block_lists без обёрточных кавычек.
# Если переменной нет в конфиге — печатает пустую строку.
_family_filter_current() {
    cfg=$(_family_filter_cfg)
    [ -f "$cfg" ] || return 0
    grep -E '^raw_block_lists=' "$cfg" 2>/dev/null \
        | head -1 \
        | sed -e 's/^raw_block_lists=//' -e 's/^"//' -e 's/"$//'
}

# Печатает true если NSFW URL присутствует в raw_block_lists, иначе false.
_family_filter_blocklist_status() {
    cur=$(_family_filter_current)
    case " $cur " in
        *" $FAMILY_FILTER_URL "*) echo true ;;
        *) echo false ;;
    esac
}

# Атомарно перезаписывает строку raw_block_lists=... в конфиге adblock-lean.
# new_value — финальный набор токенов (URL'ы и/или shortcut'ы) через пробел.
# Возврат: 0 при успехе, 1 при отсутствии конфига / отсутствии строки
# raw_block_lists= / ошибке записи. На failure исходный конфиг не тронут.
_family_filter_rewrite() {
    new_value="$1"
    cfg=$(_family_filter_cfg)
    [ -f "$cfg" ] || return 1

    tmp=$(mktemp 2>/dev/null) || return 1

    # awk заменяет первую найденную строку raw_block_lists=...; если строки
    # нет вообще — exit 2 (config broken, не пишем мусор поверх).
    if ! awk -v new="$new_value" '
        /^raw_block_lists=/ && !replaced { print "raw_block_lists=\"" new "\""; replaced=1; next }
        { print }
        END { if (!replaced) exit 2 }
    ' "$cfg" > "$tmp"; then
        rm -f "$tmp"
        logger -t family-filter "rewrite failed: raw_block_lists= не найден в $cfg"
        return 1
    fi

    # Sanity: tmp не должен быть пустым (защита от kernel-OOM в середине awk).
    [ -s "$tmp" ] || { rm -f "$tmp"; return 1; }

    # adblock-lean конфиг ставится с mode 644 (см. setup/manifest.txt).
    # mktemp создаёт 600 — после mv это бы понизило mode. Восстанавливаем.
    chmod 644 "$tmp"
    mv "$tmp" "$cfg"
}

# Включает NSFW-блок: добавляет URL в raw_block_lists, если его там ещё нет.
_family_filter_blocklist_on() {
    cur=$(_family_filter_current)
    case " $cur " in
        *" $FAMILY_FILTER_URL "*) return 0 ;;
    esac
    new=$(printf '%s %s' "$cur" "$FAMILY_FILTER_URL" | awk '{$1=$1; print}')
    _family_filter_rewrite "$new"
}

# Выключает NSFW-блок: убирает URL из raw_block_lists.
_family_filter_blocklist_off() {
    cur=$(_family_filter_current)
    case " $cur " in
        *" $FAMILY_FILTER_URL "*) ;;
        *) return 0 ;;
    esac
    new=$(printf '%s' "$cur" | awk -v drop="$FAMILY_FILTER_URL" '
        {
            out = ""
            for (i = 1; i <= NF; i++) {
                if ($i == drop) continue
                out = (out == "" ? $i : out " " $i)
            }
            print out
        }')
    _family_filter_rewrite "$new"
}

# Печатает true / false. Sentinel-проверки достаточно: весь набор cname'ов
# добавляется и удаляется атомарно через family_safesearch_on / off.
family_safesearch_status() {
    cur=$(uci -q get dhcp.@dnsmasq[0].cname 2>/dev/null) || cur=""
    case " $cur " in
        *" $_SAFESEARCH_SENTINEL "*) echo true ;;
        *) echo false ;;
    esac
}

# Idempotent: добавляет в dhcp.@dnsmasq[0].cname только те значения, которых
# ещё нет (точное совпадение). uci commit вызываем один раз в конце, и только
# если что-то изменилось — лишний commit триггерит ненужный rebuild конфига.
family_safesearch_on() {
    changed=0
    cur=$(uci -q get dhcp.@dnsmasq[0].cname 2>/dev/null) || cur=""
    for entry in $SAFESEARCH_CNAMES; do
        case " $cur " in
            *" $entry "*) ;;
            *)
                uci add_list dhcp.@dnsmasq[0].cname="$entry" >/dev/null 2>&1 || return 1
                cur="$cur $entry"
                changed=1
                ;;
        esac
    done
    [ "$changed" = 1 ] && { uci commit dhcp >/dev/null 2>&1 || return 1; }
    return 0
}

# Idempotent: del_list по точному значению — чужие cname (если кто-то их
# добавил вручную или другой подсистемой) не трогаем.
family_safesearch_off() {
    changed=0
    for entry in $SAFESEARCH_CNAMES; do
        if uci -q del_list dhcp.@dnsmasq[0].cname="$entry" 2>/dev/null; then
            changed=1
        fi
    done
    [ "$changed" = 1 ] && { uci commit dhcp >/dev/null 2>&1 || return 1; }
    return 0
}

# Публичный API — то, что зовёт rpcd-cheburnet. Сводный статус: true ⟺ обе
# подсистемы включены. Рассинхрон (одна включена, другая нет) трактуется
# как «выключено» — пользователь нажмёт on, family_filter_on idempotent'но
# дотянет недостающее.
family_filter_status() {
    nsfw=$(_family_filter_blocklist_status)
    ss=$(family_safesearch_status)
    if [ "$nsfw" = "true" ] && [ "$ss" = "true" ]; then
        echo true
    else
        echo false
    fi
}

family_filter_on() {
    _family_filter_blocklist_on || return 1
    family_safesearch_on || return 1
    return 0
}

family_filter_off() {
    _family_filter_blocklist_off || return 1
    family_safesearch_off || return 1
    return 0
}
