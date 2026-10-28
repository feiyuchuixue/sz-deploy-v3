#!/bin/bash
# 非执行式 .env 字面值读取和原子文件操作；本模块不提供业务默认值。

_env_file_error() { printf 'env-file: %s\n' "$1" >&2; return 1; }

_env_file_key() {
  [[ "$1" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || _env_file_error '非法字段名'
}

env_file_validate_literal() {
  _env_file_key "$1" || return 1
  [[ "$2" != *"'"* && "$2" != *$'\r'* && "$2" != *$'\n'* ]] \
    || _env_file_error "$1 包含不支持的字面字符"
}

_env_file_path() {
  local __ef_path="$1" __ef_parent
  [[ ! -L "$__ef_path" && ( ! -e "$__ef_path" || -f "$__ef_path" ) ]] \
    || { _env_file_error '目标必须是普通文件且不得为符号链接'; return 1; }
  __ef_parent="$(dirname -- "$__ef_path")"
  [[ -d "$__ef_parent" ]] || { _env_file_error '目标父目录不存在'; return 1; }
  while :; do
    [[ ! -L "$__ef_parent" ]] || { _env_file_error '目标父目录不得包含符号链接'; return 1; }
    [[ "$__ef_parent" != / && "$__ef_parent" != . ]] || break
    __ef_path="$(dirname -- "$__ef_parent")"
    [[ "$__ef_path" != "$__ef_parent" ]] || break
    __ef_parent="$__ef_path"
  done
}

# 先解析整份文件再交付任何字段，避免部分导出和重复键歧义。
_env_file_parse() {
  local __ef_input="$1" __ef_line __ef_key __ef_raw __ef_value
  local -n __ef_result="$2"
  _env_file_path "$__ef_input" || return 1
  [[ -f "$__ef_input" && -r "$__ef_input" ]] || { _env_file_error '配置文件不存在或不可读'; return 1; }
  __ef_result=()
  while IFS= read -r __ef_line || [[ -n "$__ef_line" ]]; do
    [[ "$__ef_line" != *$'\r'* ]] || { _env_file_error '配置文件含 CR'; return 1; }
    [[ "$__ef_line" =~ ^[[:space:]]*(#.*)?$ ]] && continue
    [[ "$__ef_line" =~ ^([a-zA-Z_][a-zA-Z0-9_]*)=(.*)$ ]] \
      || { _env_file_error '配置行不是受支持的 KEY=VALUE'; return 1; }
    __ef_key="${BASH_REMATCH[1]}" __ef_raw="${BASH_REMATCH[2]}"
    [[ ! ${__ef_result[$__ef_key]+present} ]] \
      || { _env_file_error "$__ef_key 重复定义"; return 1; }
    case "$__ef_raw" in
      \') _env_file_error "$__ef_key 引号未闭合"; return 1 ;;
      \'*\')
        __ef_value="${__ef_raw:1:${#__ef_raw}-2}"
        [[ "$__ef_value" != *"'"* ]] || { _env_file_error "$__ef_key 包含复杂引号"; return 1; }
        ;;
      \"*\")
        __ef_value="${__ef_raw:1:${#__ef_raw}-2}"
        [[ "$__ef_value" != *'$'* && "$__ef_value" != *'`'* && "$__ef_value" != *'\'* && "$__ef_value" != *'"'* ]] \
          || { _env_file_error "$__ef_key 双引号值包含插值或转义"; return 1; }
        ;;
      *)
        [[ "$__ef_raw" =~ ^[a-zA-Z0-9_./:@%,+=!?-]*$ ]] \
          || { _env_file_error "$__ef_key 裸值不是安全字面值，请使用单引号"; return 1; }
        __ef_value="$__ef_raw"
        ;;
    esac
    __ef_result["$__ef_key"]="$__ef_value"
  done < "$__ef_input"
}

env_file_read() {
  local -A __ef_values=()
  _env_file_key "$2" || return 1
  _env_file_key "$3" || return 1
  [[ "$3" != __ef_* ]] || { _env_file_error '输出变量名使用了保留前缀'; return 1; }
  _env_file_parse "$1" __ef_values || return 1
  [[ ${__ef_values[$2]+present} ]] || return 2
  printf -v "$3" '%s' "${__ef_values[$2]}"
}

env_file_export() {
  local __ef_file="$1" __ef_name
  local -A __ef_values=()
  shift
  _env_file_parse "$__ef_file" __ef_values || return 1
  for __ef_name in "$@"; do
    _env_file_key "$__ef_name" || return 1
    [[ "$__ef_name" != __ef_* && ${__ef_values[$__ef_name]+present} ]] \
      || { _env_file_error "$__ef_name 缺失或使用保留前缀"; return 1; }
  done
  for __ef_name in "$@"; do
    printf -v "$__ef_name" '%s' "${__ef_values[$__ef_name]}"
    export "$__ef_name"
  done
}

_env_file_replace() {
  local __ef_mode="$1" __ef_file="$2" __ef_key="$3" __ef_new="${4:-}"
  local __ef_tmp __ef_line __ef_nl __ef_found=false __ef_remove
  local -A __ef_values=() __ef_remove_keys=()
  shift 3
  _env_file_key "$__ef_key" || return 1
  _env_file_path "$__ef_file" || return 1
  if [[ "$__ef_mode" == remove ]]; then
    for __ef_remove in "$__ef_key" "$@"; do
      _env_file_key "$__ef_remove" || return 1
      __ef_remove_keys["$__ef_remove"]=1
    done
  else
    env_file_validate_literal "$__ef_key" "$__ef_new" || return 1
  fi
  if [[ -e "$__ef_file" ]]; then
    _env_file_parse "$__ef_file" __ef_values || return 1
    if [[ "$__ef_mode" == missing && ${__ef_values[$__ef_key]+present} ]]; then return 0; fi
    if [[ "$__ef_mode" == set && ${__ef_values[$__ef_key]+present} && "${__ef_values[$__ef_key]}" == "$__ef_new" ]]; then return 0; fi
    if [[ "$__ef_mode" == remove ]]; then
      for __ef_remove in "${!__ef_remove_keys[@]}"; do
        [[ ! ${__ef_values[$__ef_remove]+present} ]] || __ef_found=true
      done
      [[ "$__ef_found" == true ]] || return 0
    fi
  elif [[ "$__ef_mode" == remove ]]; then
    return 0
  fi
  __ef_tmp="$(mktemp "$(dirname -- "$__ef_file")/.env-file.XXXXXX")" || return 1
  if ! (
    # Explicitly test every write: callers may invoke us in an if condition.
    if [[ -f "$__ef_file" ]]; then
      while :; do
        __ef_nl=true
        if IFS= read -r __ef_line; then :; else
          __ef_nl=false
          [[ -n "$__ef_line" ]] || break
        fi
        if [[ "$__ef_line" =~ ^([a-zA-Z_][a-zA-Z0-9_]*)= ]]; then
          __ef_remove="${BASH_REMATCH[1]}"
          if [[ "$__ef_mode" == remove && ${__ef_remove_keys[$__ef_remove]+present} ]]; then continue; fi
          if [[ "$__ef_mode" != remove && "$__ef_remove" == "$__ef_key" ]]; then
            __ef_line="$__ef_key='$__ef_new'"
          fi
        fi
        printf '%s' "$__ef_line" || exit 1
        if [[ "$__ef_nl" == true ]]; then printf '\n' || exit 1; fi
      done < "$__ef_file"
    fi
    if [[ "$__ef_mode" != remove && ! ${__ef_values[$__ef_key]+present} ]]; then
      if [[ -s "$__ef_file" && -n "$(tail -c 1 -- "$__ef_file")" ]]; then printf '\n' || exit 1; fi
      printf "%s='%s'\n" "$__ef_key" "$__ef_new" || exit 1
    fi
  ) > "$__ef_tmp"; then
    rm -f -- "$__ef_tmp"; return 1
  fi
  if [[ -e "$__ef_file" ]]; then
    if cmp -s -- "$__ef_file" "$__ef_tmp"; then rm -f -- "$__ef_tmp"; return 0; fi
    # chown may clear mode bits, so restore the original mode afterwards.
    if ! chown --reference="$__ef_file" "$__ef_tmp" || ! chmod --reference="$__ef_file" "$__ef_tmp"; then
      rm -f -- "$__ef_tmp"; return 1
    fi
  elif ! chmod 600 "$__ef_tmp"; then
    rm -f -- "$__ef_tmp"; return 1
  fi
  if ! mv -f -- "$__ef_tmp" "$__ef_file"; then rm -f -- "$__ef_tmp"; return 1; fi
}

env_file_set() { _env_file_replace set "$@"; }
env_file_add_missing() { _env_file_replace missing "$@"; }
env_file_remove() { _env_file_replace remove "$@"; }
