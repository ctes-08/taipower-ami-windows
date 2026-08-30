"use strict";

const NATIVE_HOST = "tw.taipower_ami.native_host_v2";
const HANDOFF_ACTION = "taipower_ami_native_handoff";
const NATIVE_TIMEOUT_MS = 50000;
const PAYLOAD_FIELDS = ["action", "captured_day", "enkey", "session", "version"];
let handoffInFlight = false;

function sendNativeMessageWithTimeout(payload) {
  return new Promise((resolve, reject) => {
    let port;
    let settled = false;
    let timeoutId;

    const finish = (callback, value) => {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(timeoutId);
      callback(value);
    };

    try {
      port = chrome.runtime.connectNative(NATIVE_HOST);
    } catch (error) {
      reject(new Error("native_host_missing"));
      return;
    }

    timeoutId = setTimeout(() => {
      finish(reject, new Error("native_timeout"));
      try {
        port.disconnect();
      } catch (error) {
        // The port can already be closing; the timeout result remains the same.
      }
    }, NATIVE_TIMEOUT_MS);

    port.onMessage.addListener((response) => {
      finish(resolve, response);
      try {
        port.disconnect();
      } catch (error) {
        // A one-shot response is already complete.
      }
    });

    port.onDisconnect.addListener(() => {
      if (settled) {
        return;
      }
      const detail = chrome.runtime.lastError?.message || "";
      const missing = /host.*not found|specified native messaging host not found/iu.test(detail);
      finish(
        reject,
        new Error(missing ? "native_host_missing" : "native_disconnected")
      );
    });

    try {
      port.postMessage(payload);
    } catch (error) {
      finish(reject, new Error("native_disconnected"));
      try {
        port.disconnect();
      } catch (disconnectError) {
        // The failed port has no remaining work.
      }
    }
  });
}

function isExactPayload(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return false;
  }
  const fields = Object.keys(value).sort();
  return (
    fields.length === PAYLOAD_FIELDS.length &&
    fields.every((field, index) => field === PAYLOAD_FIELDS[index])
  );
}

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (
    sender.id !== chrome.runtime.id ||
    !message ||
    message.action !== HANDOFF_ACTION
  ) {
    return false;
  }
  if (!isExactPayload(message.payload)) {
    sendResponse({
      status: "error",
      error: "本機交接訊息格式不符",
      secrets_printed: false
    });
    return false;
  }
  if (handoffInFlight) {
    sendResponse({
      status: "error",
      error: "已有一筆台電交接正在執行，請等待目前作業完成",
      secrets_printed: false
    });
    return false;
  }

  handoffInFlight = true;
  sendNativeMessageWithTimeout(message.payload).then(
    (response) => sendResponse(response),
    (error) => sendResponse({
      status: "error",
      error: error instanceof Error && error.message === "native_timeout"
        ? "本機交接超過 50 秒，已中斷交接程式"
        : error instanceof Error && error.message === "native_host_missing"
          ? "找不到本機交接程式，請重新執行安裝程式"
          : "本機交接程式已啟動，但未成功回傳結果",
      secrets_printed: false
    })
  ).finally(() => {
    handoffInFlight = false;
  });
  return true;
});
