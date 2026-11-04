"use strict";

(() => {
  const form = document.querySelector("#login-form");
  const button = document.querySelector("#login-submit");
  const feedback = document.querySelector("#login-feedback");
  const password = form.elements.password;
  let busy = false;
  form.addEventListener("submit", async event => {
    event.preventDefault();
    if (busy || !form.reportValidity()) return;
    busy = true;
    button.disabled = true;
    button.textContent = "Comprobando acceso…";
    feedback.textContent = "";
    try {
      const response = await fetch("/api/login", {
        method: "POST",
        credentials: "same-origin",
        headers: {"Content-Type": "application/json", Accept: "application/json"},
        cache: "no-store",
        body: JSON.stringify({password: password.value})
      });
      let data;
      try { data = await response.json(); }
      catch { throw new Error("La app no ha devuelto una respuesta válida. Vuelve a intentarlo."); }
      if (!response.ok || data.error) throw new Error(data.error || "No se ha podido iniciar sesión.");
      password.value = "";
      window.location.replace("/hermandad");
    } catch (error) {
      feedback.textContent = error instanceof TypeError ? "No se puede conectar con la app. Comprueba tu conexión y vuelve a intentarlo." : error.message;
      password.focus();
    } finally {
      busy = false;
      button.disabled = false;
      button.replaceChildren(document.createTextNode("Entrar en mi cuenta "), Object.assign(document.createElement("span"), {textContent: "→"}));
    }
  });
})();
