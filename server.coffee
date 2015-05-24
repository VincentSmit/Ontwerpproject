Db = require 'db'
Plugin = require 'plugin'
Timer = require 'timer'
Event = require 'event'

# Global constants, use global.<variable>
global = {
	pointsTime: 3600000
}

# ==================== Events ====================
# Game install
exports.onInstall = ->
	initializeColors()
	initializeGame()

# Game update 
exports.onUpgrade = ->	
	# Check if the color array is defined correctly
	if not Db.shared.peek('colors', '-1', 'name')?
		log 'Initialized colors again'
		initializeColors()
	
	# Check version number and upgrade if required
	version = Db.shared.peek('version')
	newVersion = version
	if not version?
		version = 0
	# Version checking
	if version < 1 # Initialize deviceId, fixes inRange system
		newVersion = 1
		Db.shared.set 'maxDeviceId', 0
	if version < 2 # Clean team neutral from the scores list and clean event about team neutral (got there because of a bug)
		newVersion = 2
		Db.shared.remove 'game', 'teams', -1
		Db.shared.iterate 'game', 'eventlist', (e) ->
			if (e.peek('conqueror')? and e.peek('conqueror') == -1) or (e.peek('leading')? and e.peek('leading') == -1)
				Db.shared.remove 'game', 'eventlist', e.key()
	if version < 3 # Change yellow color
		newVersion = 3
		initializeColors()

	# Write new version to the database
	if newVersion isnt version
		log '[onUpgrade] Upgraded from version '+version+' to '+newVersion+'.'
		Db.shared.set 'version', newVersion

# Config changes (by admin or plugin adder)
exports.onConfig = (config) ->
	if config.restart
		log '[onConfig()] Restarting game'
		initializeGame()
	
# Get background location from player.
exports.onGeoloc = (userId, geoloc) ->
	#log '[onGeoloc()] Geoloc from ' + Plugin.userName(userId) + '('+userId+'): ', JSON.stringify(geoloc)
	recieved = new Date()/1000
	if Db.shared.peek('gameState') is 1 and (recieved - (Db.shared.peek('lastNotification', userId) || 0))> 30*60
		beaconRadius = Db.shared.peek('game', 'beaconRadius')
		found=false;
		#Check if user is in range of an enemy beacon, opening the app will capture the beacon
		Db.shared.iterate 'game', 'beacons', (beacon)!->
			if (parseInt(beacon.peek('owner'),10) != parseInt(getTeamOfUser(userId),10)) and !found
				if distance(geoloc.latitude, geoloc.longitude, beacon.peek('location', 'lat'), beacon.peek('location', 'lng')) < beaconRadius
					#send notifcation
					Event.create
						unit: 'inRange'
						include: userId
						text: 'You are in range of an enemy beacon, capture it now!'
					found=true;
		#Last notification send, so that the user will not be spammed with notifications
		if found
			Db.shared.set('lastNotification', userId, recieved)


# Handle new users joining the happening
exports.onJoin = (userId) ->
	log '[onJoin()] Player ' + Plugin.userName(userId) + ' is joining the Happening'
	if Db.shared.peek 'gameState' == 1
		# Find teams with lowest number of members
		min = 99999
		lowest = []
		Db.shared.iterate 'game', 'teams', (team) !->
			if team.count() < min
				min = team.count()
				lowest = []
				lowest.push team.key()
			else if team.count() == min
				lowest.push team.key()
		# Draw a random team from those
		randomNumber = Math.floor(Math.random() * lowest.length)
		team = lowest[randomNumber]
		# Add player to team
		Db.shared.set 'game', 'teams', team, 'users', userId, 'userScore', 0
		Db.shared.set 'game', 'teams', team, 'users', userId, 'captured', 0
		Db.shared.set 'game', 'teams', team, 'users', userId, 'neutralized', 0
		Db.shared.set 'game', 'teams', team, 'users', userId, 'userName', Plugin.userName(userId)
		log '[onJoin()] Added to team ' + team

#==================== Client calls ====================
# Add a beacon (during setup phase)
exports.client_addMarker = (client, location) ->
	if Db.shared.peek('gameState') isnt 0
		log '[addMarker()] '+Plugin.userName(client), ' (id=', client, ') tried to add a marker while game is not in setup phase!'
	else
		log '[addMarker()] Adding marker: lat=', location.lat, ', lng=', location.lng
		nextNumber = 0
		while Db.shared.peek('game', 'beacons', nextNumber)?
			nextNumber++

		Db.shared.set 'game', 'beacons', nextNumber, {location: location}
		Db.shared.set 'game', 'beacons', nextNumber, 'owner', -1 
		Db.shared.set 'game', 'beacons', nextNumber, 'nextOwner', -1
		Db.shared.set 'game', 'beacons', nextNumber, 'percentage', 0
		Db.shared.set 'game', 'beacons', nextNumber, 'captureValue', 10
		Db.shared.set 'game', 'beacons', nextNumber, 'action', "none"

exports.client_deleteBeacon = (client, location) ->	
	#Finding the right beacon
	if Db.shared.peek('gameState') isnt 0
		log '[deleteBeacon()] '+Plugin.userName(client), ' (id=', client, ') tried to delete a beacon while game is not in setup phase!'
	else
		Db.shared.iterate 'game', 'beacons', (beacon) !->
			if beacon.peek('location', 'lat') == location.lat and beacon.peek('location', 'lng') == location.lng
				log '[deleteBeacon()] Deleted beacon: key='+beacon.key()+', lat=', location.lat, ', lng=', location.lng
				Db.shared.remove 'game', 'beacons', beacon.key()
	
# Set the round time unit and number
exports.client_setRoundTime = (roundTimeNumber, roundTimeUnit) ->
	log '[setRoundTime()] RoundTime set to: ' + roundTimeNumber + ' ' + roundTimeUnit
	Db.shared.set 'game', 'roundTimeNumber', roundTimeNumber
	Db.shared.set 'game', 'roundTimeUnit', roundTimeUnit

# Set the number of teams
exports.client_setTeams = (teams) ->
	log '[setTeams()] Teams set to: ', teams
	Db.shared.set 'game', 'numberOfTeams', teams

# Set the game boundaries
exports.client_setBounds = (one, two) ->
	Db.shared.set 'game', 'bounds', {one: one, two: two}

# Get clients ingame user ID
# exports.client_getIngameUserId = (client) ->
# 	client.reply 

exports.client_getNewDeviceId = (client, result) ->
	newId = (Db.shared.peek('maxDeviceId'))+1
	log '[getDeviceId()] newId ' + newId + ' send to ' + Plugin.userName(client) + " (" + client + ")"
	Db.shared.set 'maxDeviceId', newId
	result.reply newId

exports.client_log = (userId, message) ->
	log '[log()] Client:'+Plugin.userName(userId)+":"+userId+": "+message

# Start the game
exports.client_startGame = ->
	setTimer()
	userIds = Plugin.userIds()
	Db.shared.set 'game', 'startTime', new Date()/1000
	teams = Db.shared.peek('game','numberOfTeams')
	team = 0
	while(userIds.length > 0)
		randomNumber = Math.floor(Math.random() * userIds.length)
		Db.shared.set 'game', 'teams', team, 'users', userIds[randomNumber], 'userScore', 0
		Db.shared.set 'game', 'teams', team, 'users', userIds[randomNumber], 'captured', 0
		Db.shared.set 'game', 'teams', team, 'users', userIds[randomNumber], 'neutralized', 0
		Db.shared.set 'game', 'teams', team, 'users', userIds[randomNumber], 'userName', Plugin.userName(userIds[randomNumber])
		log '[startGame()] Team', team, 'has player', Plugin.userName(userIds[randomNumber]) 
		userIds.splice(randomNumber,1)
		team++
		team = 0 if team >= teams
	Db.shared.iterate 'game', 'teams', (team) !->
		Db.shared.set 'game', 'teams', team.key(), 'teamScore', 0
		Db.shared.set 'game', 'teams', team.key(), 'captured', 0
		Db.shared.set 'game', 'teams', team.key(), 'neutralized', 0
	Db.shared.set 'gameState', 1 # Set gameState at the end, because this triggers a repaint at the client so we want all data prepared before that
	Event.create
    	unit: 'startGame'
    	text: "The game has started!"

# Checkin location for capturing a beacon		
exports.client_checkinLocation = (client, location, device, accuracy) ->
	if Db.shared.peek 'gameState' is not 1
		log '[checkinLocation()] Client ', client, ' (', Plugin.userName(client), ') tried to capture beacon while game is not running!'
	else
		log '[checkinLocation()] client: ', client, ', location: lat=', location.lat, ', lng=', location.lng
		beacons = Db.shared.ref('game', 'beacons')
		beaconRadius = Db.shared.peek('game', 'beaconRadius')
		beacons.iterate (beacon) ->
			current = beacon.peek('inRange', client)?
			beaconDistance = distance(location.lat, location.lng, beacon.peek('location', 'lat'), beacon.peek('location', 'lng'))
			newStatus = beaconDistance < beaconRadius
			if newStatus != current
				# Cancel timers of ongoing caputes/neutralizes (new ones will be set below if required)
				Timer.cancel 'onCapture', {beacon: beacon.key(), players: getInrangePlayers(beacon.key())}
				Timer.cancel 'onNeutralize', {beacon: beacon.key(), players: getInrangePlayers(beacon.key())}
				removed = undefined;
				if newStatus
					if not device? # Deal with old clients by denying them to be added to inRange
						log '[checkinLocation()] Denied adding to inRange, no deviceId provided: id=' + client + ', name=' + Plugin.userName(client) 
						return
					if accuracy > beaconRadius
						log '[checkinLocation()] Denied adding to inRange of '+Plugin.userName(client)+' ('+client+'), accuracy too low: '+accuracy+'m'
						return
					owner = beacon.peek 'owner'
					log '[checkinLocation()] Added to inRange: id=' + client + ', name=' + Plugin.userName(client) + ', deviceId=' + device
					beacon.set 'inRange', client, device

					# TODO do stuff for inrange timeout

					# Start takeover
				else
					inRangeValue = beacon.peek('inRange', client)
					if inRangeValue == 'true' || inRangeValue == device
						log '[checkinLocation()] Removed from inRange: id=' + client + ', name=' + Plugin.userName(client) + ', deviceId=' + device
						# clean takeover
						beacon.remove 'inRange', client
						removed = client
					else
						log '[checkinLocation()] Denied removing from inRange, deviceId does not match: id=' + client + ', name=' + Plugin.userName(client) + ', deviceId=' + device, ', inRangeValue=' + inRangeValue
				#log 'removed=', removed
				# ========== Handle changes for inRange players ==========
				# Determine members per team
				teamMembers = (0 for team in [0..5])
				beacon.iterate 'inRange', (player) !->
					if parseInt(player.key(), 10) != parseInt(removed, 10)
						team = getTeamOfUser(player.key())
						teamMembers[team] = teamMembers[team]+1
				#log 'teamMembers count: ', teamMembers	

				# Determine who is competing
				max = 0
				competing = []
				for team in [0..5]
					if teamMembers[team] > max
						max = teamMembers[team]
						competing = []
						competing.push team
					else if teamMembers[team] == max
						competing.push team
				# Update percentage taken for current time
				log '[checkinLocation()] Competing teams=', competing
				updateBeaconPercentage(beacon)

				# Check if there should be progress
				if competing.length == 1
					# Team will capture the flag
					activeTeam = competing[0]
					if activeTeam != owner
						beacon.set 'nextOwner', activeTeam
						percentage = beacon.peek 'percentage'
						if owner == -1
							# Capturing
							log '[checkinLocation()] Team ', activeTeam, ' is capturing beacon ', beacon.key()
							beacon.set 'actionStarted', new Date()/1000
							beacon.set 'action', 'capture'
							# Set timer for capturing
							Timer.set (100-percentage)*10*30, 'onCapture', {beacon: beacon.key()}
						else
							# Neutralizing
							log '[checkinLocation()] Team ', activeTeam, ' is neutralizing beacon ', beacon.key()
							beacon.set 'actionStarted', new Date()/1000
							beacon.set 'action', 'neutralize'
							Timer.set percentage*10*30, 'onNeutralize', {beacon: beacon.key()}
					else
						log '[checkinLocation()] Active team already has the beacon, ', activeTeam, '=', owner

				else
					# No progess, stand-off
					beacon.set 'actionStarted', new Date()/1000
					beacon.set 'action', 'none'
					if competing.length > 1
						log '[checkinLocation()] Capture of beacon ', beacon.key(), ' on hold, competing teams: ', competing
					else
						log '[checkinLocation()] Capture of beacon ', beacon.key(), ' stopped, left the area'

# Update the takeover percentage of a beacon depening on current action and the passed time
updateBeaconPercentage = (beacon) ->
	currentPercentage = beacon.peek 'percentage'
	action = beacon.peek 'action'
	actionStarted = beacon.peek 'actionStarted'
	if action is 'capture'
		time = (new Date()/1000)-actionStarted
		newPercentage = currentPercentage+(time/30*100)
		newPercentage = 100 if newPercentage>100
		beacon.set 'percentage', newPercentage
	else if action is 'neutralize'
		time = (new Date()/1000)-actionStarted
		newPercentage = currentPercentage-(time/30*100)
		newPercentage = 0 if newPercentage<0
		beacon.set 'percentage', newPercentage



#==================== Functions called by timers ====================
# Called by the beacon capture timer
# args.beacon: beacon key
exports.onCapture = (args) ->
	beacon = Db.shared.ref 'game', 'beacons', args.beacon
	nextOwner = beacon.peek('nextOwner')
	inRangeOfTeam = getInrangePlayersOfTeamArray(args.beacon, nextOwner)
	log '[onCapture()] Team ', nextOwner, ' has captured beacon ', beacon.key(), ', inRange players of team: '+inRangeOfTeam
	beacon.set 'percentage', 100
	beacon.set 'owner', nextOwner
	beacon.set 'actionStarted', new Date()/1000
	beacon.set 'action', 'none'
	
	# Set a timer to gain teamscore overtime
	log '[onCapture()] pointsTime: '+global.pointsTime						
	Timer.set global.pointsTime, 'overtimeScore', {beacon: beacon.key()}

	# Add event log entrie(s)
	maxId = Db.shared.ref('game', 'eventlist').incr 'maxId'
	Db.shared.set 'game', 'eventlist', maxId, 'timestamp', new Date()/1000
	Db.shared.set 'game', 'eventlist', maxId, 'type', "capture"
	Db.shared.set 'game', 'eventlist', maxId, 'beacon', beacon.key()
	Db.shared.set 'game', 'eventlist', maxId, 'conqueror', nextOwner

	# Handle push notifications
	# TODO: Personalize for team members or dubed players
	Event.create
		unit: 'capture'
		text: "Team " + Db.shared.peek('colors', nextOwner , 'name') + " captured a beacon"

	# Give 1 person of the team the individual points
	modifyScore inRangeOfTeam[0], beacon.peek('captureValue')

	# Increment captures per team and per capturer
	for player in inRangeOfTeam
		Db.shared.modify 'game', 'teams', getTeamOfUser(player) , 'users', player, 'captured', (v) -> v+1
		#log player + " from team " + getTeamOfUser(player) + " captured " + Db.shared.peek('game', 'teams', getTeamOfUser(player), 'users', player, 'captured') + " beacons"
	Db.shared.modify 'game', 'teams', nextOwner, 'captured', (v) -> v+1
    # Modify beacon value
	beacon.modify 'captureValue', (v) -> v - 1 if beacon.peek('captureValue') > 1
	
	# The game will end in 1 hour if all the beacons are captured by one team
	capOwner = Db.shared.peek('game', 'beacons', '0', 'owner')
	log 'capOwner', capOwner
	allBeaconsCaptured = true; 
	Db.shared.iterate 'game', 'beacons', (beacon) ->
		if capOwner isnt beacon.peek('owner')
			log 'capOwner2', beacon.peek('owner')
			allBeaconsCaptured = false
			log 'capturedBeaconState', allBeaconsCaptured
	log 'allbeaconscapturedFinal', allBeaconsCaptured
	endTime=Db.shared.peek('game', 'endTime')
	if allBeaconsCaptured and endTime-Plugin.time()>(global.pointsTime/1000)
		owner = Db.shared.peek('colors', nextOwner , 'name')
		Event.create
			unit: 'captureAll'
			text: "Team " + Db.shared.peek('colors', beacon.get('owner'), 'name') + " has captured all beacons, the game will end in 1 hour if you don't reconquer!!"
		end = Plugin.time()+global.pointsTime/1000 #in seconds
		log 'end', end
		Db.shared.set 'game', 'newEndTime', end
		Timer.cancel 'endGame', {}
		Timer.set global.pointsTime, 'endGame', {}
	
# Called by the beacon neutralize timer
exports.onNeutralize = (args) ->
	beacon = Db.shared.ref 'game', 'beacons', args.beacon
	neutralizer = beacon.peek('nextOwner')
	inRangeOfTeam = getInrangePlayersOfTeamArray(args.beacon, nextOwner)
	log '[onNeutralize()] Team ', neutralizer, ' has neutralized beacon ', beacon.key(), ', players: '+inRangeOfTeam
	beacon.set 'percentage', 0
	beacon.set 'owner', -1
	
	#cancel gain teamscore overtime
	Timer.cancel 'overtimeScore', {beacon: beacon.key()}
	
	#Call the timer to reset the time in the correct endtime in the database
	end = Db.shared.peek 'game', 'endTime'
	Db.shared.modify 'game', 'newEndTime', (v) -> 0
	Timer.cancel 'endGame', {}
	Timer.set (end-Plugin.time())*1000, 'endGame', {}

	# Increment neutralizes per team and per capturer
	for player in inRangeOfTeam
		Db.shared.modify 'game', 'teams', getTeamOfUser(player), 'users', player, 'neutralized', (v) -> v+1
	Db.shared.modify 'game', 'teams', neutralizer, 'neutralized', (v) -> v+1

	# Handle capturing
	updateBeaconPercentage(beacon)
	percentage = beacon.peek 'percentage'
	log '[onNeutralize()] Team ', neutralizer, ' is capturing beacon ', beacon.key(), ' (after neutralize)'

	beacon.set 'action', 'capture'
	beacon.set 'actionStarted', new Date()/1000
	# Set timer for capturing
	Timer.set (100-percentage)*10*30, 'onCapture', args
	
# Modify teamscore for possessing a beacon for a certain amount of time	
exports.overtimeScore = (args) ->
	owner = Db.shared.peek 'game', 'beacons',  args.beacon, 'owner'
	Db.shared.modify 'game', 'teams', owner, 'teamScore', (v) -> v + 1
	Timer.set global.pointsTime, 'overtimeScore', args # Every hour

#Function called when the game ends
exports.endGame = (args) ->
	log "[endGame()] The game ended! args="+args



# ==================== Functions ====================
# Get a string of the players that are inRange of a beacon
getInrangePlayers = (beacon) ->
	playersStr = undefined;
	Db.shared.iterate 'game', 'beacons', beacon, 'inRange', (player) !->
		if playersStr?
			playersStr = playersStr + ', ' + player.key()
		else
			playersStr = player.key()
	return playersStr
getInrangePlayersOfTeam = (beacon, team) ->
	playersStr = undefined;
	Db.shared.iterate 'game', 'beacons', beacon, 'inRange', (player) !->
		if getTeamOfUser(player.key()) == team
			if playersStr?
				playersStr = playersStr + ', ' + player.key()
			else
				playersStr = player.key()
	return playersStr
getInrangePlayersOfTeamArray = (beacon, team) ->
	players = [];
	Db.shared.iterate 'game', 'beacons', beacon, 'inRange', (player) !->
		if parseInt(getTeamOfUser(player.key()), 10) == parseInt(team, 10)
			players.push(player.key())
	return players

# Setup an empty game
initializeGame = ->
	# Stop all timers from the previous game
	Db.shared.iterate 'game', 'beacons', (beacon) ->
		Timer.cancel 'onCapture', {beacon: beacon.key()}
		Timer.cancel 'onNeutralize', {beacon: beacon.key()}
		Timer.cancel 'overtimeScore', {beacon: beacon.key()}
	# Reset database to defaults
	Db.shared.set 'game', {}
	#Db.shared.set 'game', 'bounds', {one: {lat: 52.249822176849, lng: 6.8396973609924}, two: {lat: 52.236578295702, lng: 6.8598246574402}} # TOOD remove
	Db.shared.set 'game', 'numberOfTeams', 2
	Db.shared.set 'game', 'beaconRadius', 200
	Db.shared.set 'game', 'roundTimeUnit', 'Days'
	Db.shared.set 'game', 'roundTimeNumber', 7
	Db.shared.set 'game', 'eventlist', 'maxId', 0

	Db.shared.set 'gameState', 0
	Db.shared.modify 'gameNumber', (v) -> (0||v)+1

initializeColors = ->
	Db.shared.set 'colors', 
		{
			'-1': {name: 'neutral', capitalizedName: 'Neutral', hex: '#999999'},
			0:    {name: 'blue',    capitalizedName: 'Blue',    hex: '#3882b6'},
			1:    {name: 'red',     capitalizedName: 'Red',     hex: '#FF3C00'},
			2:    {name: 'green',   capitalizedName: 'Green',   hex: '#009F22'},
			3:    {name: 'yellow',  capitalizedName: 'Yellow',  hex: '#E8E03F'},
			4:    {name: 'orange',  capitalizedName: 'Orange',  hex: '#FFB400'},
			5:    {name: 'purple',  capitalizedName: 'Purple',  hex: '#E700D4'}
		}

# Game timer
setTimer = ->
	if Db.shared.peek('game', 'roundTimeUnit') is 'Months'
		seconds = Db.shared.peek('game', 'roundTimeNumber')*2592000
	else if Db.shared.peek('game', 'roundTimeUnit') is 'Days'
		seconds = Db.shared.peek('game', 'roundTimeNumber')*86400
	else if Db.shared.peek('game', 'roundTimeUnit') is 'Hours'
		seconds = Db.shared.peek('game', 'roundTimeNumber')*3600
	end = Plugin.time()+seconds #in seconds
	Db.shared.set 'game', 'endTime', end
	Timer.cancel 'endGame', {}
	Timer.set seconds*1000, 'endGame', {} #endGame is the function called when the timer ends
		
# Calculate distance
distance = (inputLat1, inputLng1, inputLat2, inputLng2) ->
	r = 6378137
	rad = Math.PI / 180
	lat1 = inputLat1 * rad
	lat2 = inputLat2 * rad
	a = Math.sin(lat1) * Math.sin(lat2) + Math.cos(lat1) * Math.cos(lat2) * Math.cos((inputLng2 - inputLng1) * rad);
	return r * Math.acos(Math.min(a, 1));

# Get the team id the user is added to
getTeamOfUser = (userId) ->
	result = undefined;
	Db.shared.iterate 'game', 'teams', (team) !->
		if team.peek('users', userId, 'userName')?
			result = team.key()
	#if result is -1
	#	log 'Warning: Did not find team for userId=', userId
	return result

# Modify user and team scores by adding "points" to the current value
modifyScore = (client, points) !->
	log "[modifyScore()] client: " + client + " team: " + getTeamOfUser(client) + " points: " + points
	# calculate old number one
	teamMax = -1
	maxScore = -1
	newLead = false
	Db.shared.iterate 'game', 'teams', (team) !->
		if maxScore < team.peek('teamScore')
			teamMax = team.key()
			maxScore = team.peek('teamScore')
	
	log "[modifyScore()] TeamMax: " + teamMax + " maxScore: " + maxScore + " (1)"
	# modify user and team scores

	teamClient = getTeamOfUser(client)
	Db.shared.modify 'game', 'teams', teamClient, 'users', client, 'userScore', (v) -> v + points
	Db.shared.modify 'game', 'teams', teamClient, 'teamScore', (v) -> v + points

	Db.shared.iterate 'game', 'teams', (team) !->
		if maxScore < team.peek('teamScore') and teamMax isnt team.key()
			teamMax = team.key()
			maxScore = team.peek('teamScore')
			newLead = true
	
	log "[modifyScore()] TeamMax: " + teamMax + " maxScore: " + maxScore + " newLead: " + newLead + " (2)"

	# create score event
	# To Do: personalize for team members or dubed players
	if newLead
		maxId = Db.shared.ref('game', 'eventlist').incr 'maxId'
		Db.shared.set 'game', 'eventlist', maxId, 'timestamp', new Date()/1000
		Db.shared.set 'game', 'eventlist', maxId, 'type', "score"
		Db.shared.set 'game', 'eventlist', maxId, 'leading', teamClient
		log "[modifyScore()] Team " + Db.shared.peek('colors', teamMax, 'name') + " took the lead!"
		Event.create
			unit: 'score'
			text: "Team " + Db.shared.peek('colors', teamMax, 'name') + " took the lead!"

refreshInrangeTimer = (client, device) ->
	log '[refreshInRangeTimer()] Refreshing timer for '+Plugin.userName(client)+' ('+client+') on device '+device
	# TODO
