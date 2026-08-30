"use strict";

const OFFICIAL_ORIGIN = "https://service.taipower.com.tw";
const COOKIE_URL = `${OFFICIAL_ORIGIN}/ebpps2/`;
const DASHBOARD_PREFIX = "/ebpps2/amichart/amidashball/";
const HANDOFF_ACTION = "taipower_ami_native_handoff";
const POPUP_TIMEOUT_MS = 55000;

const button = document.getElementById("handoff");
const statusNode = document.getElementById("status");

function setStatus(message, kind = "") {
  statusNode.textContent = message;
  statusNode.className = `status ${kind}`.trim();
}

function withTimeout(promise, milliseconds) {
  let timeoutId;
  const timeout = new Promise((resolve, reject) => {
    timeoutId = setTimeout(
      () => reject(new Error("本機交接超過 55 秒，已停止等待")),
      milliseconds
    );
  });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timeoutId));
}

function taipeiDay() {
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: "Asia/Taipei",
    year: "numeric",
    month: "2-digit",
    day: "2-digit"
  }).formatToParts(new Date());
  const values = Object.fromEntries(parts.map((part) => [part.type, part.value]));
  return `${values.year}-${values.month}-${values.day}`;
}

function parseDashboardIdentity(href) {
  const url = new URL(href);
  if (
    url.origin !== OFFICIAL_ORIGIN ||
    url.search ||
    url.hash ||
    !url.pathname.startsWith(DASHBOARD_PREFIX)
  ) {
    throw new Error("AMI 入口不是預期的台電網址");
  }
  const encoded = url.pathname.slice(DASHBOARD_PREFIX.length);
  if (!encoded || encoded.includes("/")) {
    throw new Error("AMI 識別碼格式不符");
  }
  const enkey = decodeURIComponent(encoded);
  if (
    enkey.length < 8 ||
    enkey.length > 512 ||
    enkey.includes("/") ||
    enkey.includes("\\") ||
    /[\u0000-\u0020]/u.test(enkey)
  ) {
    throw new Error("AMI 識別碼格式不符");
  }
  return enkey;
}

async function captureAmiHref(tabId) {
  const results = await chrome.scripting.executeScript({
    target: {tabId},
    func: () => {
      const prefix = "/ebpps2/amichart/amidashball/";
      if (location.pathname.startsWith(prefix)) {
        return location.href;
      }
      const hrefs = [...document.querySelectorAll(`a[href*="${prefix}"]`)]
        .map((element) => element.href)
        .filter((href, index, all) => all.indexOf(href) === index);
      return hrefs.length === 1 ? hrefs[0] : null;
    }
  });
  return results.length === 1 ? results[0].result : null;
}

async function handoff() {
  button.disabled = true;
  setStatus("正在檢查登入狀態……");
  try {
    const [tab] = await chrome.tabs.query({active: true, currentWindow: true});
    if (!tab || typeof tab.id !== "number" || !tab.url) {
      throw new Error("找不到目前分頁");
    }
    const currentUrl = new URL(tab.url);
    if (currentUrl.origin !== OFFICIAL_ORIGIN) {
      throw new Error("請先切到官方台電登入後頁面");
    }

    const href = await captureAmiHref(tab.id);
    if (!href) {
      throw new Error("找不到 AMI 入口；請回到台電登入後首頁再試");
    }
    const enkey = parseDashboardIdentity(href);

    const cookies = await chrome.cookies.getAll({url: COOKIE_URL, name: "SESSION"});
    const sessions = cookies.filter((cookie) =>
      cookie.domain.replace(/^\./u, "") === "service.taipower.com.tw" &&
      cookie.path === "/ebpps2" &&
      cookie.secure === true &&
      cookie.httpOnly === true &&
      typeof cookie.value === "string" &&
      cookie.value.length >= 8 &&
      cookie.value.length <= 512 &&
      !/[\u0000-\u0020]/u.test(cookie.value)
    );
    if (sessions.length !== 1) {
      throw new Error("找不到唯一且有效的台電 SESSION，請重新登入");
    }

    setStatus("台電唯讀驗證與 HA 交接中……");
    const response = await withTimeout(
      chrome.runtime.sendMessage({
        action: HANDOFF_ACTION,
        payload: {
          version: 1,
          action: "import",
          session: sessions[0].value,
          enkey,
          captured_day: taipeiDay()
        }
      }),
      POPUP_TIMEOUT_MS
    );
    if (!response || response.status !== "ok") {
      throw new Error(response?.error || "本機交接程式沒有成功回應");
    }
    setStatus("完成：HA 將在 1 分鐘內驗證並同步資料", "ok");
  } catch (error) {
    const message = error instanceof Error ? error.message : "未知錯誤";
    setStatus(`失敗：${message}`, "error");
  } finally {
    button.disabled = false;
  }
}

button.addEventListener("click", handoff);
