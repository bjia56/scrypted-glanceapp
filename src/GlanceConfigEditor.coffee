import { ScryptedDeviceBase } from '@scrypted/sdk'
import { writeFile } from 'fs/promises'
import path from 'path'

DEFAULT_CONFIG_URL = "https://raw.githubusercontent.com/glanceapp/glance/3b79c8e09fc9d3056e978006d7989e0e1f70c6bc/docs/glance.yml"

SERVER_CONFIG = """\
# WARNING: Do not modify this section. It is managed by the plugin.
server:
  port: ${PORT}
  base-url: ${BASE_URL}

"""

class GlanceConfigEditor extends ScryptedDeviceBase
    constructor: (nativeId, parentPlugin) ->
        super nativeId
        @parentPlugin = parentPlugin
        @configPath = path.join process.env.SCRYPTED_PLUGIN_VOLUME, 'glance.yml'
        @configReady = new Promise (resolve, reject) =>
            @initializeConfig resolve, reject

    initializeConfig: (resolve, reject) ->
        existingConfig = @storage.getItem 'glance_config'
        if existingConfig
            await @writeConfigToDisk existingConfig
            resolve()
        else
            try
                @console.log "Fetching default glance configuration..."
                response = await fetch DEFAULT_CONFIG_URL
                unless response.ok
                    throw new Error "Failed to fetch default config: #{response.statusText}"

                defaultConfig = await response.text()
                finalConfig = SERVER_CONFIG + defaultConfig

                @storage.setItem 'glance_config', finalConfig
                await @writeConfigToDisk finalConfig
                resolve()
            catch e
                reject e

    writeConfigToDisk: (config) ->
        await writeFile @configPath, config
        @console.log "Glance configuration updated at #{@configPath}"

    saveScript: (script) ->
        return unless script.script?
        @storage.setItem 'glance_config', script.script
        await @writeConfigToDisk script.script

    loadScripts: ->
        config = @storage.getItem 'glance_config' || ''
        return {
            'glance.yml':
                name: 'glance.yml'
                script: config
                language: 'yaml'
        }

    eval: (source, variables = {}) ->
        throw new Error "Evaluation is not supported for glance configuration."

export default GlanceConfigEditor
