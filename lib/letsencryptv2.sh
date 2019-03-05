#!/bin/bash
set -e

source "${LETS_ENCRYPT_WWW_LIB_PATH}/ssl.sh"
source "${LETS_ENCRYPT_WWW_LIB_PATH}/jwt.sh"
source "${LETS_ENCRYPT_WWW_LIB_PATH}/http.sh"
source "${LETS_ENCRYPT_WWW_LIB_PATH}/json.sh"
source "${LETS_ENCRYPT_WWW_LIB_PATH}/utils.sh"
source "${LETS_ENCRYPT_WWW_LIB_PATH}/base64.sh"
source "${LETS_ENCRYPT_WWW_LIB_PATH}/formatter.sh"

_CA="https://acme-"${LEWWW_ENV:-staging-}"v02.api.letsencrypt.org/directory"
_CA_URLS=
_CA_ACCOUNT=
_CA_ACCOUNT_RSA=
_CA_ORDER=
_CA_CHALLENGE_ARGS=
_CA_TT="$(get_timestamp)"

_check_dependence() {
  formatter_check_lib_dependence && ssl_check_lib_dependence && http_check_lib_dependence
}

_lev2_new_account() {
  _CA_ACCOUNT_RSA="${CERTDIR}/account-key-${_CA_TT}.pem"
  ssl_generate_rsa_2048 "${_CA_ACCOUNT_RSA}"
}

_get_new_account_url() {
  echo "$(get_json_url_by_name newAccount)"
}

_get_account_pubExponent() {
  printf '%x' "$(ssl_get_rsa_publicExponent "${_CA_ACCOUNT_RSA}")"
}

_get_account_pubExponent64() {
  _get_account_pubExponent | hex2bin | urlbase64
}

_get_account_pubMod() {
  ssl_get_rsa_pubMod64 "${_CA_ACCOUNT_RSA}"
}

_get_account_pubMod64() {
  _get_account_pubMod | hex2bin | urlbase64
}

_get_signed64() {
  local protected64="${1}"
  local payload64="${2}"

  echo "$(printf '%s' "${protected64}.${payload64}" | ssl_sign_data_with_cert "${_CA_ACCOUNT_RSA}" | urlbase64)"
}

_get_data_json() {
  local protected64="${1}"
  local payload64="${2}"
  local signed64="${3}"

  echo '{"protected": "'"${protected64}"'", "payload": "'"${payload64}"'", "signature": "'"${signed64}"'"}'
}

_get_account_url() {
  local accountID="$(echo "${_CA_ACCOUNT}" | get_json_int_value id)"
  local newAccountURL="$(_get_new_account_url)"
  local accountBase=${newAccountURL/new-acct/acct}

  echo "${accountBase}/${accountID}"
}

_get_rsa_pub_exponent64() {
  printf '%x' "$(ssl_get_rsa_publicExponent "${_CA_ACCOUNT_RSA}")" | hex2bin | urlbase64
}

_get_rsa_pub_mode64() {
  ssl_get_rsa_pubMod64 "${_CA_ACCOUNT_RSA}" | hex2bin | urlbase64
}

_post_signed_request() {
  local url="${1}"
  local protected64="${2}"
  local payload64="${3}"

  local signed64=$(_get_signed64 "${protected64}" "${payload64}")
  local data=$(_get_data_json "${protected64}" "${payload64}" "${signed64}")

  http_post "${url}" "${data}"
}

lev2_new_nonce() {
  http_head $(get_json_url_by_name newNonce) | grep -i ^Replay-Nonce: | awk -F ': ' '{print $2}' | rm_new_line
}

_get_jws() {
  local pubExponent64="$(_get_account_pubExponent64)"
  local pubMod64="$(_get_account_pubMod64)"
  local url="$(_get_new_account_url)"
  local nonce="$(lev2_new_nonce)"

  get_jws_json "${pubExponent64}" "${pubMod64}" "${url}" "${nonce}"
}

lev2_reg_account() {
  local url="$(_get_new_account_url)"

  local payload='{"contact":["mailto:me@sunwei.xyz"], "termsOfServiceAgreed": true}'
  local payload64="$(printf '%s' "${payload}" | urlbase64)"
  local protected64="$(printf '%s' "$(_get_jws)" | urlbase64)"

  _CA_ACCOUNT="$(_post_signed_request "${url}" "${protected64}" "${payload64}")"
}

_get_jwt() {
  local url="${1}"
  local accountURL="$(_get_account_url)"
  local nonce="$(lev2_new_nonce)"

  get_jwt_json "${accountURL}" "${url}" "${nonce}"
}

_get_new_order_url() {
  echo "$(get_json_url_by_name newOrder)"
}

lev2_new_order() {
  local FQDN="${1}"
  local url="$(_get_new_order_url)"

  local payload='{"identifiers": [{"type": "dns", "value": "'"${FQDN}"'"}]}'
  local payload64=$(printf '%s' "${payload}" | urlbase64)
  local protected64="$(printf '%s' "$(_get_jwt "${url}")" | urlbase64)"

  _CA_ORDER="$(_post_signed_request "${url}" "${protected64}" "${payload64}")"
}

_get_thumb_print() {
  local pubExponent64="$(_get_account_pubExponent64)"
  local pubMod64="$(_get_account_pubMod64)"

  printf '{"e":"%s","kty":"RSA","n":"%s"}' "${pubExponent64}" "${pubMod64}" | ssl_get_data_binary | urlbase64
}

_build_authz() {
  local orderAuthz="$(echo ${_CA_ORDER} | get_json_array_value authorizations | rm_quotes | rm_space)"
  local response="$(http_get "${orderAuthz}" | clean_json)"

  local identifier="$(echo "${response}" | get_json_dict_value identifier | get_json_string_value value)"

  local challenge="$(echo "${response}" | get_json_array_value challenges | split_arr_mult_value | grep \"dns-01\")"
  local challengeToken="$(echo "${challenge}" | get_json_string_value token)"
  local challengeURL="$(echo "${challenge}" | get_json_string_value url)"

  local thumbPrint="$(_get_thumb_print)"
  local keyAuthHook="$(printf '%s' "${challengeToken}.${thumbPrint}" | ssl_get_data_binary | urlbase64)"

  _CA_CHALLENGE_ARGS="$(printf '{"identifier":"%s","token":"%s","keyAuth":"%s","url":"%s"}' "${identifier}" "${challengeToken}" "${keyAuthHook}" "${challengeURL}")"
}

DNSPod_RECORD_ID=
lev2_deploy_challenge() {
  local providerHook="${1}"

  local identifier="$(echo "${_CA_CHALLENGE_ARGS}" | get_json_string_value identifier)"
  local keyAuth="$(echo "${_CA_CHALLENGE_ARGS}" | get_json_string_value keyAuth)"
  DNSPod_RECORD_ID="$("${providerHook}" "create_txt_record" ${identifier} ${keyAuth})"
}

lev2_clean_challenge() {
  local providerHook="${1}"

  local identifier="$(echo "${_CA_CHALLENGE_ARGS}" | get_json_string_value identifier)"
  "${providerHook}" "rm_txt_record" ${identifier} ${DNSPod_RECORD_ID}
}

lev2_check_challenge_status() {
  local providerHook="${1}"

  local identifier="$(echo "${_CA_CHALLENGE_ARGS}" | get_json_string_value identifier)"

  local deployStatus=False
  while [[ "${deployStatus}" = False ]]; do
    sleep 5
    deployStatus="$("${providerHook}" "find_txt_record" ${identifier})"
  done
}

lev2_valid_challenge() {
  local accountRSA="${_CA_ACCOUNT_RSA}"
  local challengeArgs="${_CA_CHALLENGE_ARGS}"

  local keyAuth="$(echo "${challengeArgs}" | get_json_string_value keyAuth)"
  local url="$(echo "${challengeArgs}" | get_json_string_value url)"

  local payload='{"keyAuthorization": "'"${keyAuth}"'"}'
  local payload64=$(printf '%s' "${payload}" | urlbase64)
  local protected64="$(printf '%s' "$(_get_jwt "${url}")" | urlbase64)"

  result="$(_post_signed_request "${url}" "${protected64}" "${payload64}" | clean_json)"
  reqSta="$(printf '%s\n' "${result}" | get_json_string_value status)"

  while [[ "${reqSta}" = "pending" ]]; do
      sleep 1
      result="$(http_get "${url}")"
      reqSta="$(printf '%s\n' "${result}" | get_json_string_value status)"
  done

  if [[ "${reqSta}" = "valid" ]]; then
      echo " + Challenge is valid!"
  else
      echo " - Challenge failed!"
  fi
}

lev2_sign_csr() {
  check_fd_3

  local accountRSA="${_CA_ACCOUNT_RSA}" csr="${2}"
  local finalize="$(echo "${_CA_ORDER}" | get_json_string_value finalize)"

  local csr64="$( <<<"${csr}" openssl req -config "$(ssl_get_conf)" -outform DER | urlbase64)"
  local payload='{"csr": "'"${csr64}"'"}'
  local payload64=$(printf '%s' "${payload}" | urlbase64)
  local protected64="$(printf '%s' "$(_get_jwt "${finalize}")" | urlbase64)"

  local result="$(_post_signed_request "${finalize}" "${protected64}" "${payload64}" | clean_json)"
  local certUrl="$(echo "${result}" | get_json_string_value certificate)"
  local crt="$(http_get "${certUrl}")"

  echo " + Checking certificate..."
#  ssl_print_in_text_form <<<"${crt}"

  echo "${crt}" >&3
  echo " + Done!"
}

lev2_produce_cert() {
  local timestamp="${_CA_TT}"
  local tmpCert="$(mk_tmp_file)"
  local tmpChain="$(mk_tmp_file)"

  awk '{print >out}; /----END CERTIFICATE-----/{out=tmpChain}' out="${tmpCert}" tmpChain="${tmpChain}" "${CERTDIR}/cert-${timestamp}.pem"

  mv "${CERTDIR}/cert-${timestamp}.pem" "${CERTDIR}/fullchain-${timestamp}.pem"

  cat "${tmpCert}" > "${CERTDIR}/cert-${timestamp}.pem"
  cat "${tmpChain}" > "${CERTDIR}/chain-${timestamp}.pem"

  rm "${tmpCert}" "${tmpChain}"
}

lev2_get_timestamp() {
  echo "${_CA_TT}"
}

lev2_init() {
  _check_dependence
  _lev2_new_account

  _CA_URLS=$(http_get "${_CA}")
}