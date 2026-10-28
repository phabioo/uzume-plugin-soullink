-- Entry module of the SoulLink & Nuzlocke plugin: wires the run model to the app.
local controller = require("app.controller")

uz.log.info(uz.i18n.t("loaded", { version = (uz.plugin and uz.plugin.version) or "?" }))
-- Host event source: "uz" since Uzume 0.22; older apps only know "fb".
local host = rawget(_ENV, "uz") ~= nil and "uz" or "fb"
local app = controller.new(uz, host)
app:start()
