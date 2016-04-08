
google      = require('googleapis')
youtubeCms  = google.youtubePartner('v1')
youtubeData = google.youtube('v3')
async       = require 'async'
timeOut     = 600

scopes = [
  "https://www.googleapis.com/auth/youtubepartner",
  "https://www.googleapis.com/auth/youtube.force-ssl",
  "https://www.googleapis.com/auth/youtube"
]

module.exports = util =
  auth: (key, done)->
    jwtClient = new google.auth.JWT(key.client_email, null, key.private_key, scopes, null)
    jwtClient.authorize (err, tokens)->
      google.options({ auth: jwtClient })
      return done(err, { jwtClient: jwtClient, tokens: tokens })

  syncWhitelist: (list, done)->
    async.mapSeries list, (channel, next)->
      util.syncChannel channel, (err, res)->
        return next(err, res)
    , (err, updatedList)->
      return done(err, updatedList)

  syncChannel: (channel, done)->
    channel.note = []
    channel.error = []

    async.eachSeries channel.whitelistOwner, (owner, next)->
      util.updateCms(channel, owner, next)
    , (err, result)->
      done(err, channel)

  updateCms: (channel, owner, done)->
    util.delay(youtubeCms.whitelists.get, timeOut) { id: channel.channelId, onBehalfOfContentOwner: owner }, (err, item)->
      if err and err.code isnt 404
        return util.handleError("Can't find channel from whitelist(csm: #{owner})", err, channel, done)

      if !item and channel.active
        util.delay(youtubeCms.whitelists.insert, timeOut) { resource: util.formatChannelData(channel), onBehalfOfContentOwner: owner }, (err, res)->
          if err
            return util.handleError("Can't insert channel to whitelist(cms: #{owner})", err, channel, done)

          channel.note.push "inserted to whitelist(cms: #{owner})"
          return done(err, channel)

      else if item and !channel.active
        util.delay(youtubeCms.whitelists.delete, timeOut) { id: channel.channelId, onBehalfOfContentOwner: owner }, (err, res)->
          if err
            return util.handleError("Can't delete cahnnel from whitelist(cms: #{owner})", err, channel, done)

          channel.note.push "deleted from whitelist(cms: #{owner})"
          return done(err, channel)
      else
        channel.note.push "nothing need to do(cms: #{owner})"
        return done(null, channel)

  delay: (func, time)->
    (params, cb)->
      setTimeout ()->
        func(params, cb)
      , time

  handleError: (note, err, channel, done)->
    note = note + " error: #{err.message}"
    channel.note.push note
    channel.error.push err

    return done(null, channel)

  formatChannelData: (channel)->
    item =
      "kind": "youtubePartner#whitelist"
      "id": channel.channelId

  removeCmsClaims: (params, done)->
    { cms, vid } = params

    util.delay(youtubeCms.claimSearch.list, timeOut) { onBehalfOfContentOwner: cms, videoId: vid }, (err, res)->
      return done(err, null) if err
      claimIds = _.map res.items, (i)-> return  i.id
      async.eachSeries claimIds, (cid, next)->
        util.delay(youtubeCms.claims.get, timeOut) { claimId: cid }, (err, res)->
          return next(err, res) if err
          console.log 'show get claim res'
          console.log err
          console.log res

          config =
            onBehalfOfContentOwner: cms
            claimId: cid
            resource:
              status: 'inactive'

          util.delay(youtubeCms.claims.update, timeOut) config, (err, res)->
            return next(err, res)
      , (err)->
        return done(err, null)

  removeClaims: (params, done)->
    { channels, user, videoId, whitelistOwners } = params
    util.validateVideoId videoId, channels, (err, canRemove)->
      return done(err, null) if err
      return done(Error("You don't have the permission to remove the channel."), null) unless canRemove

      async.eachSeries whitelistOwners, (cms, next)->
        util.removeCmsClaims { cms: cms, vid: videoId }, next
      (err, result)->
        return done(err, null)
      
  validateVideoId: (vId, channels, done)->
    found = false
    async.eachSeries channels, (channel, next)->
      return next(null, found) if found

      util.getVideosByChannel { channelId: channel }, (err, vds)->
        return next(err, false) if err

        _.each vds, (v)-> found = true if v.contentDetails.videoId is vId
        return next(null, null)
    , (err)->
      return done(err, found)

  getVideosByChannel: (params, done)->
    { channelId, playlist } = params
    playlist = 'uploads' unless playlist

    config =
      part: 'contentDetails'
      id: channelId

    youtubeData.channels.list config, (err, res)->
      return done(err, null) if err
      list = res.items[0].contentDetails.relatedPlaylists[playlist]
      return done(null, []) unless list

      config =
        part: 'contentDetails,snippet'
        maxResults: 50
        playlistId: list

      youtubeData.playlistItems.list config, (err, res)->
        return done(err, res.items)

