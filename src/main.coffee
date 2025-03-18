import { ScryptedDeviceBase, ScryptedDeviceType, ScryptedInterface, HttpRequestHandler } from '@scrypted/sdk'
import sdk from '@scrypted/sdk'

import { arch, platform } from 'os'
import path from 'path'
import { existsSync } from 'fs'
import { mkdir, readdir, rmdir, chmod, writeFile } from 'fs/promises'
import { spawn } from 'child_process'
import { createServer } from 'net'

import AdmZip from 'adm-zip'
import * as tar from 'tar'

import glance from './glance.json'

DL_ARCH = () ->
    switch arch()
        when 'x64' then 'amd64'
        when 'arm64' then 'arm64'
        when 'arm' then 'armv7'
        else throw new Error "unsupported architecture #{arch()}"

DL_PLATFORM = () ->
    switch platform()
        when 'darwin' then 'darwin'
        when 'linux' then 'linux'
        when 'win32' then 'windows'
        else throw new Error "unsupported platform #{platform()}"

DL_EXT = () ->
    if DL_PLATFORM() == 'windows'
        'zip'
    else
        'tar.gz'

VERSION = glance.version

DEFAULT_CONFIG_URL = "https://raw.githubusercontent.com/glanceapp/glance/3b79c8e09fc9d3056e978006d7989e0e1f70c6bc/docs/glance.yml"

SERVER_CONFIG = """
# WARNING: Do not modify this section. It is managed by the plugin.
server:
  port: ${PORT}
  base-url: ${BASE_URL}
"""

class GlancePlugin extends ScryptedDeviceBase
    constructor: (nativeId) ->
        super nativeId
        @exe = new Promise (resolve, reject) =>
            @doDownload resolve
            .catch reject
        @glanceProcess = null
        @glancePort = null
        @baseUrl = "/endpoint/@bjia56/scrypted-glanceapp/"
        @discoverDevices()
        @startGlanceWhenReady()

        @configPath = path.join process.env.SCRYPTED_PLUGIN_VOLUME, 'glance.yml'
        @configReady = new Promise (resolve, reject) =>
            @initializeConfig resolve, reject

    initializeConfig: (resolve, reject) ->
        while true
            try
                @storage.getItem 'glance_config'
            catch e
                await new Promise (r) => setTimeout r, 1000
                continue
            break

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
                finalConfig = SERVER_CONFIG + '\n\n' + defaultConfig

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

    doDownload: (resolve) ->
        url = "https://github.com/glanceapp/glance/releases/download/#{VERSION}/glance-#{DL_PLATFORM()}-#{DL_ARCH()}.#{DL_EXT()}"

        pluginVolume = process.env.SCRYPTED_PLUGIN_VOLUME
        installDir = path.join pluginVolume, "glance-#{VERSION}-#{DL_PLATFORM()}-#{DL_ARCH()}"

        platform_specific_path = ->
            if DL_PLATFORM() == 'windows'
                path.join installDir, 'glance.exe'
            else
                path.join installDir, 'glance'

        unless existsSync installDir
            @console.log "Clearing old glance installations"
            existing = await readdir pluginVolume
            existing.forEach (file) =>
                if file.startsWith 'glance-'
                    try
                        await rmdir path.join(pluginVolume, file), { recursive: true }
                    catch e
                        console.error e

            await mkdir installDir, { recursive: true }

            @console.log "Downloading glance from #{url}"
            response = await fetch url
            unless response.ok
                throw new Error "Failed to download glance: #{response.statusText}"

            archive = await response.arrayBuffer()
            archivePath = path.join installDir, "glance.#{DL_EXT()}"
            await writeFile archivePath, Buffer.from(archive)

            if DL_EXT() == 'zip'
                admZip = new AdmZip archivePath
                admZip.extractAllTo installDir, true
            else
                await tar.x { file: archivePath, cwd: installDir }

        exe = platform_specific_path()
        unless DL_PLATFORM() == 'windows'
            await chmod exe, 0o755

        @console.log "Glance executable ready at: #{exe}"
        resolve exe

    findFreePort: ->
        new Promise (resolve, reject) ->
            server = createServer()
            server.listen 0, ->
                port = server.address().port
                server.close ->
                    resolve port
            server.on 'error', reject

    startGlanceWhenReady: ->
        Promise.all([@exe, @configReady, @findFreePort()]).then ([exePath, _, port]) =>
            @glancePort = port
            @startGlance exePath, port

    startGlance: (exePath, port) ->
        unless existsSync @configPath
            @console.error "Glance config file is missing: #{@configPath}"
            return

        env = Object.assign({}, process.env, {
            PORT: port.toString()
            BASE_URL: @baseUrl
        })

        @console.log "Starting Glance: #{exePath} -config #{@configPath} on port #{port}"
        @glanceProcess = spawn exePath, ['-config', @configPath], { env }

        @glanceProcess.stdout.on 'data', (data) =>
            process.stdout.write "[Glance] #{data}"

        @glanceProcess.stderr.on 'data', (data) =>
            process.stderr.write "[Glance] #{data}"

        @glanceProcess.on 'exit', (code, signal) =>
            @console.error "Glance process exited with code #{code}, signal #{signal}"
            setTimeout (=> @startGlanceWhenReady()), 20000  # Restart after 20s

    discoverDevices: ->
        @applicationInfo = {
            name: 'Glance'
            description: 'Glance Dashboard App'
            icon: 'fa-tachometer'
            href: @baseUrl
        }

    onRequest: (request, response) ->
        unless @glancePort
            response.send "Glance is not running", { code: 500 }
            return

        # Remove root path from the request URL
        trimmedUrl = request.url.replace(@baseUrl, '')

        # Build the full Glance server URL
        glanceUrl = "http://localhost:#{@glancePort}/#{trimmedUrl}"

        # Prepare request options
        requestOptions =
            method: request.method
            headers: request.headers
            body: if !(["GET", "HEAD"].includes request.method) then request.body else undefined

        try
            #@console.log "Forwarding request to Glance: #{glanceUrl}"
            glanceResponse = await fetch glanceUrl, requestOptions
            responseBody = await glanceResponse.text()

            response.send responseBody,
                code: glanceResponse.status
                headers: Object.fromEntries glanceResponse.headers.entries()

        catch error
            @console.error "Error forwarding request to Glance: #{error}"
            response.send "Error contacting Glance", { code: 500 }

export default GlancePlugin
