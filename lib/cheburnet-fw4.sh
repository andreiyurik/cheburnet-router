# lib/cheburnet-fw4.sh — side-effecting fw4/nftables-хелперы для setup-скриптов.
#
# Source-only: ничего не выполняет, только определяет функции. Не имеет shebang.
#
# Подключение:
#   . /opt/cheburnet/lib/cheburnet-fw4.sh    # на роутере
#   . lib/cheburnet-fw4.sh                    # из репо-чекаута / тестов
#
# В отличие от cheburnet-utils.sh, функции здесь ТРОГАЮТ живой nftables —
# это намеренно. Вынесено в отдельный файл, чтобы не ломать pure-контракт
# cheburnet-utils.sh (от которого зависят T2-тесты).

# ─────────────────────────────────────────────────────────────────────────────
# cheburnet_fw4_apply_rule CHAIN COMMENT EXPR
# ─────────────────────────────────────────────────────────────────────────────
#
# Идемпотентно вставляет правило в начало живой nft-цепочки в table `inet fw4`.
# Альтернатива `/etc/init.d/firewall reload`: применяет одно правило мгновенно
# (миллисекунды), не пересобирая весь fw4-ruleset (1-3 минуты на слабом железе)
# и не разрывая активные соединения.
#
# Аргументы:
#   CHAIN   — имя цепочки в `inet fw4` (например, `input_wan`, `forward_lan`).
#             Цепочка должна уже существовать — fw4 reload должен был отработать
#             хотя бы раз (после firstboot или после добавления новой зоны).
#   COMMENT — уникальная строка-метка для идентификации правила. По ней
#             функция вычищает свои старые экземпляры при повторных запусках.
#             ВНИМАНИЕ: comment не должен содержать кавычек, символов \ или \n.
#             Алфавит-цифры-дефисы — самый безопасный набор.
#   EXPR    — nft-выражение `<match> <verdict>` без `comment "..."` (хелпер
#             добавит сам). Например: `tcp dport 22 reject` или
#             `ip saddr 192.168.1.0/24 oifname "wan" counter drop`.
#
# Возвращает:
#   0 — правило успешно применено
#   1 — невалидные аргументы или цепочка inet fw4 CHAIN не существует
#       (печатает причину в stderr)
#   2 — `nft insert` упал (печатает stderr nft в основной поток)
#
# ВАЖНО: caller отвечает за персистентность через UCI ОТДЕЛЬНО. Этот хелпер
# трогает только живой nft-ruleset, без `uci set firewall.@rule`.
# При следующем штатном `firewall reload` (например, после reboot) живые
# правила исчезнут — UCI-копия их вернёт.
#
# Пример:
#   cheburnet_fw4_apply_rule input_wan "Block-SSH-from-WAN" "tcp dport 22 reject"
cheburnet_fw4_apply_rule() {
    _chain="$1"
    _comment="$2"
    _expr="$3"

    if [ -z "$_chain" ] || [ -z "$_comment" ] || [ -z "$_expr" ]; then
        echo "✗ cheburnet_fw4_apply_rule: нужны 3 аргумента (chain, comment, expr)" >&2
        unset _chain _comment _expr
        return 1
    fi

    if ! nft list chain inet fw4 "$_chain" >/dev/null 2>&1; then
        echo "✗ цепочка inet fw4 $_chain не существует" >&2
        echo "  fw4 ещё не инициализирован — ожидался хотя бы один firewall reload" >&2
        echo "  до этого момента (обычно делается на шаге 01-amneziawg)." >&2
        unset _chain _comment _expr
        return 1
    fi

    # Cleanup старых правил с этим comment в этой цепочке. Без него повторный
    # запуск установщика плодил бы дубликаты в forward_lan / input_wan.
    # `nft -a list` добавляет `# handle N` к каждому правилу — по этим N мы
    # и удаляем. Если handle уже исчез (был удалён предыдущей итерацией) —
    # `nft delete` тихо проигнорируется через `|| true`.
    nft -a list chain inet fw4 "$_chain" 2>/dev/null \
        | awk -v c="$_comment" '
            $0 ~ "comment \"" c "\"" {
                for (i=1; i<=NF; i++) if ($i == "handle") print $(i+1)
            }
          ' \
        | while read -r _h; do
            [ -n "$_h" ] && nft delete rule inet fw4 "$_chain" handle "$_h" 2>/dev/null || true
          done

    # `insert` (а не `add`) ставит в НАЧАЛО цепочки — раньше любых
    # пропускающих jump'ов. Это правильное место для блокирующих правил
    # (kill-switch, deny-from-wan и т.п.).
    if ! nft "insert rule inet fw4 $_chain $_expr comment \"$_comment\"" 2>&1; then
        echo "✗ nft insert упал для правила '$_comment' в $_chain" >&2
        unset _chain _comment _expr
        return 2
    fi

    unset _chain _comment _expr
    return 0
}
