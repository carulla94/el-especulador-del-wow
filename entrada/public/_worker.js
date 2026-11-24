// oro-hermandad.pages.dev: every request goes, untouched, to the Worker el-especulador-del-wow (service binding PANEL).
// The Worker sees this address in request.url, so its redirects, cookies and same-origin checks belong to this address.
export default {
  fetch(request, env) {
    return env.PANEL.fetch(request);
  }
};
