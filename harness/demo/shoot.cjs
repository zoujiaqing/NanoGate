// 对本地演示环境（./up.sh）截 README / 宣传用的图。用法（在 NewGate 根目录）：
//   PW_PATH=$PWD/netonapi-client/node_modules/playwright OUT=netonapi-backend/docs/screenshots node harness/demo/shoot.cjs
const { chromium } = require(process.env.PW_PATH);
const OUT = process.env.OUT || "/tmp/netonapi-shots";
const WEB = process.env.WEB || "http://localhost:8880";
const ADMIN = process.env.ADMIN || "http://localhost:8888";
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const view = { viewport: { width: 1440, height: 900 }, deviceScaleFactor: 1.5, locale: "zh-CN", colorScheme: "light" };

async function shot(page, url, name, opts = {}) {
  if (url) await page.goto(url, { waitUntil: "load", timeout: 90000 }).catch(() => {});
  await sleep(opts.wait ?? 2000);
  // 开发模式（next dev）左下角的指示器不该出现在宣传图里
  await page.addStyleTag({ content: "nextjs-portal{display:none!important}" }).catch(() => {});
  await page.screenshot({ path: `${OUT}/${name}.png`, fullPage: !!opts.full });
  console.log("shot", name);
}

(async () => {
  require("fs").mkdirSync(OUT, { recursive: true });
  const browser = await chromium.launch();

  // 网站：门户与用户控制台（大客户 Acme 智能，有协议价）
  const web = await (await browser.newContext(view)).newPage();
  await shot(web, `${WEB}/`, "web-home");
  await shot(web, `${WEB}/pricing`, "web-pricing");
  await web.goto(`${WEB}/login`, { waitUntil: "load" }).catch(() => {});
  await sleep(1500);
  await web.locator("input").first().fill("acme_ai");
  await web.fill('input[type="password"]', "Demo-acme_ai-2026");
  await web.keyboard.press("Enter");
  await web.waitForURL(/console/, { timeout: 60000 }).catch(() => {});
  await shot(web, `${WEB}/console`, "console-overview", { wait: 3000 });
  await shot(web, `${WEB}/console/gateway/model`, "console-models");
  await shot(web, `${WEB}/console/gateway/key`, "console-keys");
  await shot(web, `${WEB}/console/gateway/usage`, "console-usage");

  // 管理后台
  const ap = await (await browser.newContext(view)).newPage();
  await ap.goto(`${ADMIN}/login`, { waitUntil: "load" }).catch(() => {});
  await sleep(2000);
  await ap.locator("input").nth(0).fill("admin");
  await ap.fill('input[type="password"]', "admin123");
  await ap.keyboard.press("Enter");
  await ap.waitForURL((u) => !u.toString().includes("/login"), { timeout: 60000 }).catch(() => {});
  await sleep(3000);
  await shot(ap, `${ADMIN}/gateway/overview`, "admin-overview", { wait: 4000 });
  await shot(ap, `${ADMIN}/gateway/price`, "admin-pricing", { wait: 3500 });
  await shot(ap, `${ADMIN}/gateway/channel`, "admin-channels", { wait: 3000 });
  await shot(ap, `${ADMIN}/gateway/user-price`, "admin-negotiated-list", { wait: 3000 });
  // 协议定价详情：搜 acme_ai 进去
  await ap.locator('input[placeholder]').first().fill("acme_ai");
  await ap.keyboard.press("Enter");
  await sleep(3500);
  await shot(ap, null, "admin-negotiated-detail");
  await shot(ap, `${ADMIN}/gateway/log`, "admin-logs", { wait: 3000 });
  await browser.close();
})().catch((e) => { console.error(e); process.exit(1); });
