import {test, expect} from "@playwright/test";
import fs from "node:fs/promises";

function observe(page) {
  const unexpected = [], errors = [];
  page.on("pageerror", error => errors.push(error.message));
  page.on("request", request => {
    const url = new URL(request.url());
    if (/^https?:$/.test(url.protocol) && (url.origin !== "http://127.0.0.1:4173" ||
      /\/api(?:\/|$)/.test(url.pathname))) unexpected.push(url.href);
  });
  return {unexpected, errors};
}

test("la cartera persiste en IndexedDB real bajo la ruta de proyecto y exporta una copia", async ({page}) => {
  const seen = observe(page);
  await page.goto("./");
  await expect(page.locator("#status-title")).toHaveText("Esperando los primeros datos de tu mercado");
  await expect(page.getByText("Edición GitHub Pages · Datos locales", {exact:true})).toBeVisible();
  await expect(page.locator("#logout-button")).toBeHidden();
  await page.locator('[data-view="auctioneer"]').click();
  await expect(page.locator("#view-auctioneer")).toBeVisible();
  await expect(page.locator("#device-form")).toBeHidden();
  await page.locator('[data-view="settings"]').click();
  await page.locator('#settings-form [name="capitalGold"]').fill("100");
  await page.getByRole("button", {name:"Guardar ajustes",exact:true}).click();
  await expect(page.locator("#settings-feedback")).toContainText("Ajustes guardados.");
  await expect(page.locator("#metric-capital")).toHaveText(/100\s*g/);

  await page.locator('[data-view="transactions"]').click();
  await page.locator("#view-transactions .section-heading").getByRole("button", {name:"Añadir movimiento",exact:true}).click();
  const form = page.locator("#transaction-form");
  await form.locator('[name="itemId"]').fill("2770");
  await form.locator('[name="name"]').fill("Cobre de prueba");
  await form.locator('[name="quantity"]').fill("2");
  await form.locator('[name="unitGold"]').fill("3");
  await form.getByRole("button", {name:"Guardar movimiento",exact:true}).click();
  await expect(page.locator("#transaction-dialog")).toBeHidden();
  await expect(page.locator("#metric-capital")).toHaveText(/94\s*g/);
  await page.locator('[data-view="inventory"]').click();
  await expect(page.locator("#inventory-body")).toContainText("Cobre de prueba");
  await page.reload();
  await expect(page.locator("#inventory-body")).toContainText("Cobre de prueba");
  await expect(page.locator("#metric-capital")).toHaveText(/94\s*g/);
  await expect(page.locator("#inventory-body tr").first().getByRole("cell").nth(1)).toHaveText("2");
  await page.locator('[data-view="settings"]').click();
  await expect(page.locator('#settings-form [name="capitalGold"]')).toHaveValue("100");
  const downloaded = page.waitForEvent("download");
  await page.locator("a[data-pages-export]").click();
  const download = await downloaded;
  const backup = JSON.parse(await fs.readFile(await download.path(), "utf8"));
  expect(backup.format).toBe("forever-mercado-backup");
  expect(backup.settings.capitalCopper).toBe(1000000);
  expect(backup.transactions).toHaveLength(1);
  expect(backup.transactions[0].quantity).toBe(2);
  expect(seen.errors).toEqual([]);
  expect(seen.unexpected).toEqual([]);
});

test("el bloqueo de IndexedDB muestra un error y no cae en la API de Cloudflare", async ({page}) => {
  const seen = observe(page);
  await page.addInitScript(() => Object.defineProperty(window, "indexedDB", {value:undefined, configurable:true}));
  await page.goto("./");
  await expect(page.locator("#status-message")).toContainText("no permite guardar los datos localmente");
  await page.locator('[data-view="settings"]').click();
  await page.locator('#settings-form [name="capitalGold"]').fill("100");
  await page.getByRole("button", {name:"Guardar ajustes",exact:true}).click();
  await expect(page.locator("#settings-feedback")).toContainText("no permite guardar los datos localmente");
  await expect(page.locator("#settings-feedback")).not.toContainText("Ajustes guardados");
  expect(seen.errors).toEqual([]);
  expect(seen.unexpected).toEqual([]);
});
