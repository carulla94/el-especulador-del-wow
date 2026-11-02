import {defineConfig} from "@playwright/test";

const baseURL = "http://127.0.0.1:4173/el-especulador-del-wow/";
export default defineConfig({
  testDir: "./test-browser",
  fullyParallel: false,
  workers: 1,
  retries: 0,
  forbidOnly: Boolean(process.env.CI),
  timeout: 30000,
  expect: {timeout:10000},
  reporter: [["list"], ["html", {open:"never"}]],
  use: {baseURL, browserName:"chromium", headless:true, viewport:{width:1280,height:900},
    trace:"retain-on-failure", screenshot:"only-on-failure"},
  webServer: {command:"node scripts/serve-pages.mjs", url:baseURL, reuseExistingServer:false, timeout:15000}
});
