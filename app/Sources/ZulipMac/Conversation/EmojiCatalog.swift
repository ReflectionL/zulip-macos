import Foundation
import ZulipCoreBindings

/// The emoji a reaction can be picked from.
///
/// Names are the ones Zulip's reaction endpoint resolves, so picking an emoji needs
/// no server round trip; an emoji the server does not know comes back as a visible,
/// retryable action failure. The table lines are `code<TAB>name<TAB>search words`.
enum EmojiCatalog {
    struct Entry: Identifiable, Hashable {
        let code: String
        let name: String
        let keywords: String

        var id: String { code }
        var glyph: String { EmojiCatalog.glyph(forCode: code) ?? ":\(name):" }
        var target: ReactionTarget { ReactionTarget(name: name, code: code) }
    }

    /// The few emoji offered first, with the names Zulip's own picker uses.
    static let recommended: [Entry] = [
        Entry(code: "1f44d", name: "thumbs_up", keywords: "thumbs up like yes"),
        Entry(code: "2764", name: "heart", keywords: "heart love"),
        Entry(code: "1f604", name: "smile", keywords: "smile happy"),
        Entry(code: "1f602", name: "joy", keywords: "joy laugh funny"),
        Entry(code: "1f389", name: "tada", keywords: "tada party celebrate"),
        Entry(code: "1f440", name: "eyes", keywords: "eyes look"),
        Entry(code: "1f64f", name: "pray", keywords: "pray thanks please"),
        Entry(code: "2705", name: "check", keywords: "check done yes"),
        Entry(code: "1f525", name: "fire", keywords: "fire hot"),
        Entry(code: "1f680", name: "rocket", keywords: "rocket ship launch"),
    ]

    static let all: [Entry] = table.split(separator: "\n").compactMap { line in
        let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        return Entry(code: String(parts[0]), name: String(parts[1]), keywords: String(parts[2]))
    }

    /// The characters for a Zulip emoji code ("1f44d", "0023-20e3"); nil when the
    /// code is not a sequence of code points.
    static func glyph(forCode code: String) -> String? {
        let parts = code.split(separator: "-")
        let scalars = parts.compactMap { UInt32($0, radix: 16).flatMap(Unicode.Scalar.init) }
        guard !scalars.isEmpty, scalars.count == parts.count else { return nil }
        var result = String.UnicodeScalarView()
        for (index, scalar) in scalars.enumerated() {
            result.append(scalar)
            let next = index + 1 < scalars.count ? scalars[index + 1] : nil
            let needsEmojiPresentation = scalar.properties.isEmoji
                && !scalar.properties.isEmojiPresentation
                && (next == nil || next?.value == 0x20E3)
                && !(scalar.value < 0x80 && next == nil)
            if needsEmojiPresentation {
                result.append(Unicode.Scalar(0xFE0F)!)
            }
        }
        return String(result)
    }

    /// Entries whose name or search words start with every word of `query`; an
    /// emoji typed or pasted into the box finds itself.
    static func search(_ query: String) -> [Entry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return all }
        if trimmed.unicodeScalars.contains(where: { $0.value > 0x7F }) {
            let wanted = stripVariationSelectors(trimmed)
            return all.filter { stripVariationSelectors($0.glyph) == wanted }
        }
        let words = trimmed.split(whereSeparator: { $0 == " " || $0 == "_" || $0 == ":" })
            .map(String.init)
        return all.filter { entry in
            let candidates = entry.keywords.split(separator: " ").map(String.init)
            return words.allSatisfy { word in
                entry.name.contains(word) || candidates.contains { $0.hasPrefix(word) }
            }
        }
    }

    private static func stripVariationSelectors(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { $0.value != 0xFE0F }))
    }

    private static let table = #"""
0023-20e3	hash	hash
002a-20e3	asterisk	asterisk
0030-20e3	zero	0 keycap zero
0031-20e3	one	1 keycap one
0032-20e3	two	2 keycap two
0033-20e3	three	3 keycap three
0034-20e3	four	4 four keycap
0035-20e3	five	5 five keycap
0036-20e3	six	6 keycap six
0037-20e3	seven	7 keycap seven
0038-20e3	eight	8 eight keycap
0039-20e3	nine	9 keycap nine
00a9	copyright	copyright c
00ae	registered	registered r
203c	bangbang	bangbang double exclamation mark
2049	interrobang	exclamation interrobang mark question
2122	tm	mark tm trade trademark
2139	info	information source
2194	left_right	arrow left right swap
2195	up_down	arrow down up
2196	upper_left	arrow left up upper north west
2197	upper_right	arrow right up upper north east
2198	lower_right	arrow down lower right south east
2199	lower_left	arrow down left lower south west
21a9	reply	arrow curving hook left leftwards right with
21aa	forward	arrow curving hook left right
231a	watch	watch
231b	times_up	done hourglass
2328	keyboard	keyboard
23cf	eject_button	button eject symbol
23e9	fast_forward	button fast forward
23ea	rewind	button fast reverse rewind
23eb	double_up	arrow button double fast up
23ec	double_down	arrow button double down fast
23ed	next_track	bar black button double next pointing right track triangle vertical with skip forward
23ee	previous_track	bar black button double last left pointing previous track triangle vertical with skip back
23ef	play_pause	bar black button double or pause play pointing right triangle vertical with
23f0	alarm_clock	alarm clock
23f1	stopwatch	stopwatch
23f2	timer	clock timer
23f3	time_ticking	done flowing hourglass not sand
23f8	pause	bar button double pause vertical
23f9	stop_button	black button for square stop
23fa	record	black button circle for record
24c2	metro	circled m
25aa	black_small_square	black small square
25ab	white_small_square	small square white
25b6	play	arrow button forward play
25c0	play_reverse	arrow backward button reverse
25fb	white_medium_square	medium square white
25fc	black_medium_square	black medium square
25fd	white_medium_small_square	medium small square white
25fe	black_medium_small_square	black medium small square
2600	sunny	sun sunny
2601	cloud	cloud overcast
2602	umbrella	open umbrella
2603	snowman	snow snowman with
2604	comet	comet meteor
260e	phone	phone telephone
2611	checkbox	ballot box check with
2614	umbrella_with_rain	drops rain umbrella with
2615	coffee	beverage coffee hot
2618	shamrock	shamrock clover
261d	wait_one_second	index point pointing up of information asking a question
2620	skull_and_crossbones	and crossbones skull pirate death hazard toxic poison
2622	radioactive	radioactive sign nuclear
2623	biohazard	biohazard sign
2626	orthodox_cross	cross orthodox
262a	star_and_crescent	and crescent star islam
262e	peace	peace symbol
262f	yin_yang	yang yin
2638	wheel_of_dharma	dharma of wheel buddhism
2639	sad	face frowning white big frown
263a	smiling_face	face relaxed smiling
2640	female_sign	female sign
2642	male_sign	male sign
2648	aries	aries
2649	taurus	taurus
264a	gemini	gemini
264b	cancer	cancer
264c	leo	leo
264d	virgo	virgo
264e	libra	libra
264f	scorpius	scorpio scorpius
2650	sagittarius	sagittarius
2651	capricorn	capricorn
2652	aquarius	aquarius
2653	pisces	pisces
265f	chess_pawn	chess pawn dupe expendable
2660	spades	spade spades suit
2663	clubs	club clubs suit
2665	hearts	heart hearts suit
2666	diamonds	diamond diamonds suit
2668	hot_springs	hot hotsprings springs
267b	recycle	recycle recycling symbol
267e	infinity	infinity forever unbounded universal
267f	accessible	symbol wheelchair disabled
2692	at_work	and hammer pick
2693	anchor	anchor
2694	duel	crossed swords
2695	medical_symbol	medical symbol aesculapius staff
2696	justice	balance scale scales
2697	alchemy	alembic
2699	gear	gear settings mechanical engineer
269b	atom	atom symbol physics
269c	fleur_de_lis	de fleur lis
26a0	warning	warning caution danger
26a1	high_voltage	high voltage zap
26a7	transgender_symbol	symbol transgender
26aa	white_circle	circle white
26ab	black_circle	black circle
26b0	coffin	coffin burial grave
26b1	funeral_urn	funeral urn cremation
26bd	football	ball soccer
26be	baseball	baseball
26c4	frosty	snow snowman without
26c5	partly_sunny	behind cloud partly sun sunny cloudy
26c8	thunderstorm	and cloud lightning rain thunder with
26ce	ophiuchus	ophiuchus
26cf	mine	pick
26d1	helmet	cross helmet rescue white with worker workers hard hat safety first invincible
26d3	chains	chains
26d4	no_entry	entry no wrong way
26e9	shinto_shrine	shinto shrine
26ea	church	church
26f0	mountain	mountain
26f1	beach_umbrella	ground on parasol umbrella
26f2	fountain	fountain
26f3	hole_in_one	flag golf hole in
26f4	ferry	ferry
26f5	boat	boat sailboat
26f7	skier	skier
26f8	ice_skate	ice skate
26f9	ball	ball bouncing person with sports
26fa	tent	tent camping
26fd	fuel_pump	fuel fuelpump pump gas petrol
2702	scissors	scissors
2705	check	button check mark white all good approved
2708	airplane	airplane
2709	email	envelope mail
270a	fist	fist raised power
270b	hand	hand raised
270c	peace_sign	hand v victory
270d	writing	hand writing
270f	pencil	pencil pencil2
2712	black_nib	black nib
2714	check_mark	check heavy mark
2716	multiplication	heavy multiplication multiply x
271d	cross	cross latin christianity
2721	star_of_david	david of star judaism jewish
2728	sparkles	sparkles glamour
2733	eight_spoked_asterisk	asterisk eight spoked
2734	eight_pointed_star	black eight pointed star
2744	snowflake	snowflake
2747	sparkle	sparkle
274c	cross_mark	cross mark x incorrect wrong
274e	x	button cross mark negative squared
2753	question	mark question red
2754	grey_question	grey mark question white
2755	grey_exclamation	exclamation grey mark white
2757	exclamation	exclamation heavy mark red
2763	heart_exclamation	exclamation heart heavy mark ornament
2764	heart	heart red love you
2795	plus	heavy plus sign add
2796	minus	heavy minus sign subtract
2797	division	divide division heavy sign
27a1	right	arrow right east
27b0	loop	curly loop
27bf	double_loop	curly double loop voicemail
2934	heading_up	arrow curving heading right up
2935	heading_down	arrow curving down heading right
2b05	left	arrow left west
2b06	up	arrow up north
2b07	down	arrow down south
2b1b	black_large_square	black large square
2b1c	white_large_square	large square white
2b50	star	star
2b55	circle	circle hollow o red
3030	wavy_dash	dash wavy
303d	part_alternation	alternation mark part
3297	japanese_congratulations_button	button congratulations japanese
3299	japanese_secret_button	button japanese secret
1f004	mahjong	dragon mahjong red
1f0cf	joker	black joker
1f170	a	a blood button type
1f171	b	b blood button type
1f17e	o	blood button o o2 type
1f17f	parking	button p parking
1f18e	ab	ab blood button type
1f191	cl	button cl
1f192	cool	button cool
1f193	free	button free
1f194	id	button id
1f195	new	button new
1f196	ng	button ng
1f197	squared_ok	button ok
1f198	sos	button sos
1f199	squared_up	button up
1f19a	vs	button vs
1f201	japanese_here_button	button here japanese koko
1f202	japanese_service_charge_button	button charge japanese sa service
1f21a	japanese_free_of_charge_button	button charge free japanese of u7121
1f22f	japanese_reserved_button	button japanese reserved u6307
1f232	japanese_prohibited_button	button japanese prohibited u7981
1f233	japanese_vacancy_button	button japanese u7a7a vacancy
1f234	japanese_passing_grade_button	button grade japanese passing u5408
1f235	japanese_no_vacancy_button	button japanese no u6e80 vacancy
1f236	japanese_not_free_of_charge_button	button charge free japanese not of u6709
1f237	japanese_monthly_amount_button	amount button japanese monthly u6708
1f238	japanese_application_button	application button japanese u7533
1f239	japanese_discount_button	button discount japanese u5272
1f23a	japanese_open_for_business_button	business button for japanese open u55b6
1f250	japanese_bargain_button	advantage bargain button ideograph japanese
1f251	japanese_acceptable_button	accept acceptable button japanese
1f300	cyclone	cyclone hurricane typhoon
1f301	foggy	foggy
1f302	closed_umbrella	closed umbrella
1f303	night	night stars with
1f304	mountain_sunrise	mountains over sunrise
1f305	sunrise	sunrise ocean
1f306	sunset	at city cityscape dusk sunset
1f307	city_sunrise	city sunrise sunset
1f308	rainbow	rainbow pride lgbtq
1f309	bridge	at bridge night
1f30a	ocean	ocean water wave
1f30b	volcano	volcano
1f30c	milky_way	milky way night sky
1f30d	earth_africa	africa earth europe globe showing
1f30e	earth_americas	americas earth globe showing
1f30f	earth_asia	asia australia earth globe showing
1f310	www	globe meridians with
1f311	new_moon	moon new
1f312	waxing_crescent_moon	crescent moon waxing
1f313	first_quarter_moon	first moon quarter
1f314	waxing_moon	gibbous moon waxing
1f315	full_moon	full moon
1f316	waning_gibbous_moon	gibbous moon waning
1f317	last_quarter_moon	last moon quarter
1f318	waning_crescent_moon	crescent moon waning
1f319	moon	crescent moon
1f31a	new_moon_face	face moon new with
1f31b	goodnight	face first moon quarter with
1f31c	last_quarter_moon_face	face last moon quarter with
1f31d	moon_face	face full moon with
1f31e	sun_face	face sun with
1f31f	glowing_star	glowing star star2
1f320	shooting_star	shooting star stars wish
1f321	temperature	thermometer warm
1f324	mostly_sunny	behind cloud small sun white with
1f325	cloudy	behind cloud large sun white
1f326	sunshowers	behind cloud rain sun white with and partly sunny
1f327	rainy	cloud rain with soaked drenched
1f328	snowy	cloud snow with snowstorm
1f329	lightning	cloud lightning with storm
1f32a	tornado	cloud tornado with
1f32b	fog	fog hazy
1f32c	windy	blowing face wind mother nature
1f32d	hotdog	dog hot hotdog
1f32e	taco	taco
1f32f	burrito	burrito
1f330	chestnut	chestnut
1f331	seedling	seedling sprout
1f332	evergreen_tree	evergreen tree
1f333	tree	deciduous tree
1f334	palm_tree	palm tree
1f335	cactus	cactus
1f336	hot_pepper	hot pepper chili
1f337	tulip	tulip flower
1f338	cherry_blossom	blossom cherry
1f339	rose	rose
1f33a	hibiscus	hibiscus
1f33b	sunflower	sunflower
1f33c	blossom	blossom
1f33d	corn	corn ear of maize
1f33e	harvest	ear of rice sheaf
1f33f	herb	herb plant
1f340	lucky	clover four leaf
1f341	maple_leaf	leaf maple
1f342	fallen_leaf	fallen leaf
1f343	leaves	fluttering in leaf leaves wind fall
1f344	mushroom	mushroom
1f345	tomato	tomato
1f346	eggplant	eggplant
1f347	grapes	grapes
1f348	melon	melon
1f349	watermelon	watermelon
1f34a	orange	mandarin orange tangerine
1f34b	lemon	lemon
1f34c	banana	banana
1f34d	pineapple	pineapple
1f34e	apple	apple red
1f34f	green_apple	apple green
1f350	pear	pear
1f351	peach	peach
1f352	cherries	cherries
1f353	strawberry	strawberry
1f354	hamburger	hamburger
1f355	pizza	pizza
1f356	meat	bone meat on
1f357	drumstick	leg poultry
1f358	senbei	cracker rice
1f359	onigiri	ball rice
1f35a	rice	cooked rice
1f35b	curry	curry rice
1f35c	ramen	bowl ramen steaming noodles
1f35d	spaghetti	spaghetti
1f35e	bread	bread
1f35f	fries	french fries
1f360	yam	potato roasted sweet
1f361	dango	dango
1f362	oden	oden
1f363	sushi	sushi
1f364	tempura	fried shrimp
1f365	naruto	cake fish swirl with
1f366	soft_serve	cream ice icecream soft
1f367	shaved_ice	ice shaved
1f368	ice_cream	cream ice gelato
1f369	donut	doughnut
1f36a	cookie	cookie
1f36b	chocolate	bar chocolate
1f36c	candy	candy
1f36d	lollipop	lollipop
1f36e	custard	custard flan
1f36f	honey	honey pot
1f370	cake	cake shortcake
1f371	bento	bento box
1f372	food	food of pot stew soup
1f373	cooking	cooking egg fried
1f374	fork_and_knife	and fork knife eating utensils
1f375	tea	handle tea teacup without
1f376	sake	sake
1f377	wine	glass wine
1f378	cocktail	cocktail glass
1f379	tropical_drink	drink tropical
1f37a	beer	beer mug
1f37b	beers	beer beers clinking mugs
1f37c	baby_bottle	baby bottle
1f37d	hungry	and cutlery fork knife plate with meal table setting lets eat
1f37e	champagne	bottle champagne cork popping with
1f37f	popcorn	popcorn
1f380	ribbon	ribbon decoration
1f381	gift	gift wrapped present
1f382	birthday	birthday cake
1f383	jack-o-lantern	jack lantern o pumpkin
1f384	holiday_tree	christmas tree
1f385	santa	claus santa
1f386	fireworks	fireworks
1f387	sparkler	sparkler
1f388	balloon	balloon celebration
1f389	tada	party popper tada
1f38a	confetti	ball confetti party
1f38b	wish_tree	tanabata tree
1f38c	crossed_flags	crossed flags solidarity
1f38d	bamboo	bamboo decoration pine
1f38e	dolls	dolls japanese
1f38f	carp_streamer	carp flags streamer
1f390	wind_chime	chime wind
1f391	moon_ceremony	ceremony moon rice scene viewing
1f392	backpack	backpack satchel school
1f393	graduate	board cap graduation mortar
1f396	military_medal	medal military
1f397	reminder_ribbon	reminder ribbon
1f399	studio_microphone	microphone studio
1f39a	volume	level slider
1f39b	control_knobs	control knobs
1f39e	film	film frames strip
1f39f	ticket	admission tickets
1f3a0	carousel	carousel horse merry go round
1f3a1	ferris_wheel	ferris wheel
1f3a2	roller_coaster	coaster roller
1f3a3	fishing	and fish fishing pole
1f3a4	microphone	microphone mike mic
1f3a5	movie_camera	camera movie
1f3a6	cinema	cinema movie theater
1f3a7	headphones	headphone headphones
1f3a8	art	art artist palette painting
1f3a9	top_hat	hat top tophat
1f3aa	circus	circus tent
1f3ab	pass	ticket
1f3ac	action	board clapper
1f3ad	performing_arts	arts performing drama theater
1f3ae	video_game	game video
1f3af	direct_hit	bullseye dart darts bulls eye
1f3b0	slot_machine	machine slot
1f3b1	billiards	8 8ball ball pool
1f3b2	dice	die game
1f3b3	strike	bowling
1f3b4	playing_cards	cards flower playing
1f3b5	music	musical note
1f3b6	musical_notes	musical notes
1f3b7	saxophone	saxophone
1f3b8	guitar	guitar
1f3b9	piano	keyboard musical
1f3ba	trumpet	trumpet
1f3bb	violin	violin
1f3bc	musical_score	musical score
1f3bd	running_shirt	running sash shirt with
1f3be	tennis	tennis
1f3bf	ski	ski skis
1f3c0	basketball	basketball
1f3c1	checkered_flag	checkered chequered flag race go start
1f3c2	snowboarder	snowboarder
1f3c3	running	person runner running
1f3c4	surf	person surfer surfing
1f3c5	medal	medal sports
1f3c6	trophy	trophy winner
1f3c7	horse_racing	horse racing riding
1f3c8	american_football	american football
1f3c9	rugby	football rugby
1f3ca	swim	person swimmer swimming
1f3cb	lift	lifter lifting person weight weights work out lift gym
1f3cc	golf	golfer golfing person
1f3cd	motorcycle	motorcycle racing
1f3ce	racecar	car racing
1f3cf	cricket_game	and ball bat cricket game
1f3d0	volleyball	volleyball
1f3d1	field_hockey	and ball field hockey stick
1f3d2	ice_hockey	and hockey ice puck stick
1f3d3	ping_pong	and ball paddle ping pong table tennis
1f3d4	snowy_mountain	capped mountain snow
1f3d5	campsite	camping
1f3d6	beach	beach umbrella with
1f3d7	construction	building construction
1f3d8	houses	buildings house houses
1f3d9	city	cityscape skyline
1f3da	derelict_house	building derelict house condemned
1f3db	classical_building	building classical
1f3dc	desert	desert
1f3dd	island	desert island
1f3de	national_park	national park
1f3df	stadium	stadium
1f3e0	house	house
1f3e1	suburb	garden house with
1f3e2	office	building office
1f3e3	japan_post	japanese office post
1f3e4	post_office	european office post
1f3e5	hospital	hospital
1f3e6	bank	bank
1f3e7	atm	atm sign
1f3e8	hotel	hotel
1f3e9	love_hotel	hotel love
1f3ea	convenience_store	convenience store
1f3eb	school	school
1f3ec	department_store	department store
1f3ed	factory	factory
1f3ee	lantern	izakaya lantern paper red
1f3ef	shiro	castle japanese
1f3f0	castle	castle european
1f3f3	white_flag	flag waving white surrender
1f3f4	black_flag	black flag waving
1f3f5	rosette	rosette
1f3f7	label	label tag price
1f3f8	badminton	and badminton racquet shuttlecock
1f3f9	bow_and_arrow	and arrow bow archery
1f3fa	vase	amphora
1f400	rat	rat
1f401	mouse	mouse mouse2
1f402	ox	ox bull
1f403	water_buffalo	buffalo water
1f404	cow	cow cow2
1f405	tiger	tiger tiger2
1f406	leopard	leopard
1f407	rabbit	rabbit rabbit2
1f408	cat	cat cat2 meow
1f409	dragon	dragon
1f40a	crocodile	crocodile
1f40b	humpback_whale	whale whale2
1f40c	snail	snail
1f40d	snake	snake hiss
1f40e	horse	horse racehorse
1f40f	ram	ram
1f410	goat	goat
1f411	sheep	ewe sheep baa
1f412	monkey	monkey
1f413	rooster	rooster alarm cock-a-doodle-doo
1f414	chicken	chicken cluck
1f415	dog	dog dog2 woof
1f416	pig	pig pig2 oink
1f417	boar	boar
1f418	elephant	elephant
1f419	octopus	octopus
1f41a	shell	shell spiral seashell conch
1f41b	bug	bug caterpillar
1f41c	ant	ant
1f41d	bee	bee honeybee buzz
1f41e	lady_beetle	beetle lady ladybird ladybug
1f41f	fish	fish
1f420	tropical_fish	fish tropical
1f421	blowfish	blowfish
1f422	turtle	turtle tortoise
1f423	hatching	chick hatching
1f424	chick	baby chick
1f425	new_baby	baby chick facing front hatched
1f426	bird	bird
1f427	penguin	penguin
1f428	koala	koala
1f429	poodle	poodle
1f42a	arabian_camel	camel dromedary
1f42b	camel	camel hump two
1f42c	dolphin	dolphin flipper
1f42d	dormouse	face mouse
1f42e	calf	cow face
1f42f	tiger_cub	face tiger
1f430	bunny	face rabbit
1f431	kitten	cat face
1f432	dragon_face	dragon face
1f433	whale	spouting whale
1f434	pony	face horse
1f435	monkey_face	face monkey
1f436	puppy	dog face
1f437	piglet	face pig
1f438	frog	frog
1f439	hamster	hamster
1f43a	wolf	wolf
1f43b	bear	bear
1f43c	panda	face panda
1f43d	pig_nose	nose pig
1f43e	paw_prints	feet paw prints paws
1f43f	chipmunk	chipmunk
1f440	eyes	eyes looking
1f441	eye	eye
1f442	ear	ear
1f443	nose	nose
1f444	lips	lips mouth
1f445	tongue	tongue
1f446	point_up	2 backhand index point pointing up this
1f447	point_down	backhand down index point pointing
1f448	point_left	backhand index left point pointing
1f449	point_right	backhand index point pointing right
1f44a	fist_bump	facepunch fist oncoming punch
1f44b	wave	hand wave waving hello hi
1f44c	ok	hand ok got it
1f44d	+1	1 thumbs thumbsup up like
1f44e	-1	1 down thumbs thumbsdown
1f44f	clap	clap clapping hands applause
1f450	open_hands	hands open
1f451	crown	crown queen king
1f452	hat	hat womans
1f453	glasses	eyeglasses glasses spectacles
1f454	tie	necktie
1f455	shirt	shirt t tshirt
1f456	jeans	jeans denim
1f457	dress	dress
1f458	kimono	kimono
1f459	bikini	bikini
1f45a	clothing	clothes womans
1f45b	purse	purse
1f45c	handbag	handbag
1f45d	pouch	bag clutch pouch
1f45e	shoe	mans shoe
1f45f	athletic_shoe	athletic running shoe sneaker
1f460	high_heels	heel heeled high shoe
1f461	sandal	sandal womans flip flops
1f462	boot	boot womans
1f463	footprints	footprints feet
1f464	silhouette	bust in silhouette shadow
1f465	silhouettes	busts in silhouette shadows
1f466	boy	boy
1f467	girl	girl
1f468	man	man
1f469	woman	woman
1f46a	family	family
1f46b	man_and_woman_holding_hands	and couple hands holding man woman
1f46c	two_men_holding_hands	hands holding men two couple
1f46d	two_women_holding_hands	hands holding two women couple
1f46e	police	cop officer police
1f46f	dancers	bunny dancers ears people with
1f470	bride	person veil with
1f471	person_blond_hair	blond hair haired person with human
1f472	gua_pi_mao	gua man mao person pi skullcap with
1f473	turban	person turban wearing with
1f474	older_man	man old older elderly
1f475	older_woman	old older woman elderly
1f476	baby	baby
1f477	construction_worker	construction worker
1f478	princess	princess
1f479	ogre	japanese ogre
1f47a	goblin	goblin japanese
1f47b	ghost	ghost boo spooky haunted
1f47c	angel	angel baby
1f47d	alien	alien ufo
1f47e	space_invader	alien invader monster space
1f47f	devil	angry face horns imp with devil
1f480	skull	skull
1f481	information_desk_person	desk hand information person tipping
1f482	guard	guard
1f483	dancer	dancer dancing woman
1f484	lipstick	lipstick
1f485	nail_polish	care nail polish
1f486	massage	getting massage person
1f487	haircut	getting haircut person
1f488	barber	barber pole striped
1f489	injection	syringe
1f48a	medicine	pill
1f48b	lipstick_kiss	kiss mark
1f48c	love_letter	letter love
1f48d	ring	ring
1f48e	gem	gem stone crystal
1f48f	kiss	couplekiss kiss
1f490	bouquet	bouquet
1f491	couple_with_heart	couple heart with
1f492	wedding	wedding
1f493	heartbeat	beating heart heartbeat
1f494	broken_heart	broken heart heartache
1f495	two_hearts	hearts two
1f496	sparkling_heart	heart sparkling
1f497	heart_pulse	growing heart heartpulse
1f498	cupid	arrow cupid heart with smitten
1f499	blue_heart	blue heart
1f49a	green_heart	green heart envy
1f49b	yellow_heart	heart yellow of gold
1f49c	purple_heart	heart purple bravery
1f49d	gift_heart	gift heart ribbon with
1f49e	revolving_hearts	hearts revolving
1f49f	heart_box	decoration heart
1f4a0	cute	a diamond dot inside shape with kawaii
1f4a1	light_bulb	bulb light idea
1f4a2	anger	anger symbol bam pow
1f4a3	bomb	bomb
1f4a4	zzz	zzz
1f4a5	boom	boom collision explosion crash
1f4a6	sweat_drops	droplets drops sweat
1f4a7	drop	droplet water drop
1f4a8	dash	away dash dashing
1f4a9	poop	hankey of pile poo poop shit
1f4aa	muscle	biceps flexed muscle
1f4ab	seeing_stars	dizzy
1f4ac	umm	balloon speech
1f4ad	thought	balloon thought dream
1f4ae	white_flower	flower white
1f4af	100	100 hundred points
1f4b0	money	bag money moneybag
1f4b1	exchange	currency exchange
1f4b2	dollars	dollar heavy sign
1f4b3	credit_card	card credit debit
1f4b4	yen_banknotes	banknote yen
1f4b5	dollar_bills	banknote dollar
1f4b6	euro_banknotes	banknote euro
1f4b7	pound_notes	banknote pound
1f4b8	losing_money	money wings with easy come go
1f4b9	stock_market	chart increasing with yen
1f4ba	seat	seat
1f4bb	computer	computer laptop
1f4bc	briefcase	briefcase
1f4bd	gold_record	computer disk minidisc
1f4be	floppy_disk	disk floppy
1f4bf	cd	cd disk optical
1f4c0	dvd	dvd
1f4c1	organize	file folder
1f4c2	folder	file folder open
1f4c3	page_with_curl	curl page with
1f4c4	document	facing page up paper file
1f4c5	calendar	calendar date
1f4c6	date	calendar off tear
1f4c7	rolodex	card index
1f4c8	chart	chart increasing trend upwards with growing
1f4c9	downwards_trend	chart decreasing downwards trend with shrinking
1f4ca	bar_chart	bar chart
1f4cb	clipboard	clipboard
1f4cc	push_pin	pushpin thumb tack
1f4cd	pin	pushpin round sewing pin
1f4ce	paperclip	paperclip attachment
1f4cf	ruler	ruler straight straightedge
1f4d0	carpenter_square	ruler triangular
1f4d1	place_holder	bookmark tabs
1f4d2	ledger	ledger spiral notebook
1f4d3	notebook	notebook composition book
1f4d4	decorative_notebook	cover decorative notebook with
1f4d5	red_book	book closed
1f4d6	book	book open
1f4d7	green_book	book green
1f4d8	blue_book	blue book
1f4d9	orange_book	book orange
1f4da	books	books
1f4db	name_badge	badge name
1f4dc	scroll	scroll
1f4dd	memo	memo pencil note
1f4de	landline	receiver telephone home phone
1f4df	pager	pager
1f4e0	fax	fax machine
1f4e1	satellite_antenna	antenna satellite
1f4e2	loudspeaker	loudspeaker bullhorn
1f4e3	megaphone	mega megaphone shout
1f4e4	outbox	outbox tray
1f4e5	inbox	inbox tray
1f4e6	package	package
1f4e7	e-mail	e email mail
1f4e8	mail_received	envelope incoming
1f4e9	mail_sent	arrow envelope with sealed
1f4ea	closed_mailbox	closed flag lowered mailbox with
1f4eb	mailbox	closed flag mailbox raised with
1f4ec	unread_mail	flag mail mailbox open raised with
1f4ed	inbox_zero	flag lowered mail mailbox no open with empty
1f4ee	mail_dropoff	postbox
1f4ef	horn	horn postal
1f4f0	headlines	newspaper
1f4f1	mobile_phone	iphone mobile phone smartphone android
1f4f2	calling	arrow calling mobile phone with
1f4f3	vibration_mode	mode vibration
1f4f4	phone_off	mobile off phone
1f4f5	no_phones	mobile no phones
1f4f6	cell_reception	antenna bars signal strength
1f4f7	camera	camera
1f4f8	taking_a_picture	camera flash with say cheese
1f4f9	video_camera	camera video recorder
1f4fa	tv	television tv
1f4fb	radio	radio
1f4fc	vhs	vhs videocassette
1f4fd	projector	film projector movie
1f4ff	prayer_beads	beads prayer
1f500	shuffle	arrows button rightwards shuffle tracks twisted
1f501	repeat	button repeat
1f502	repeat_one	button one repeat single
1f503	clockwise	arrows clockwise vertical
1f504	counterclockwise	arrows button counterclockwise return
1f505	low_brightness	brightness button dim low
1f506	brightness	bright brightness button high
1f507	mute	mute muted speaker no sound
1f508	speaker	low speaker volume
1f509	softer	medium sound speaker volume
1f50a	louder	high loud sound speaker volume
1f50b	battery	battery full
1f50c	electric_plug	electric plug
1f50d	search	glass left mag magnifying tilted find
1f50e	magnifying_glass_tilted_right	glass mag magnifying right tilted contact pointing
1f50f	privacy	ink lock locked pen with key signing digital security protected
1f510	secure	closed key lock locked with safe commitment loyalty
1f511	key	key
1f512	locked	lock locked
1f513	unlocked	unlock unlocked
1f514	notifications	bell
1f515	mute_notifications	bell no slash with
1f516	bookmark	bookmark
1f517	link	link
1f518	radio_button	button radio
1f519	back	arrow back
1f51a	end	arrow end
1f51b	on	arrow on on!
1f51c	soon	arrow soon
1f51d	top	arrow top
1f51e	underage	eighteen no one under underage nc17
1f51f	ten	10 keycap ten
1f520	capital_abcd	abcd capital input latin uppercase letters
1f521	abcd	abcd input latin lowercase alphabet
1f522	1234	1234 input numbers
1f523	symbols	input symbols
1f524	abc	abc input latin letters
1f525	fire	fire lit hot flame
1f526	flashlight	flashlight
1f527	fixing	wrench
1f528	hammer	hammer maintenance handyman handywoman
1f529	nut_and_bolt	and bolt nut screw
1f52a	knife	hocho kitchen knife betrayed
1f52b	gun	gun pistol water
1f52c	science	microscope
1f52d	telescope	telescope
1f52e	crystal_ball	ball crystal oracle future fortune telling
1f52f	dotted_six_pointed_star	dotted pointed six star
1f530	beginner	beginner for japanese symbol
1f531	trident	emblem trident
1f532	white_and_black_square	black button square
1f533	black_and_white_square	button square white
1f534	red_circle	circle red
1f535	blue_circle	blue circle large
1f536	large_orange_diamond	diamond large orange
1f537	large_blue_diamond	blue diamond large
1f538	small_orange_diamond	diamond orange small
1f539	small_blue_diamond	blue diamond small
1f53a	red_triangle_up	pointed red small triangle up
1f53b	red_triangle_down	down pointed red small triangle
1f53c	upvote	arrow button small up upwards increase
1f53d	downvote	arrow button down downwards small decrease
1f549	om	om symbol hinduism
1f54a	dove	dove of peace
1f54b	kaaba	kaaba
1f54c	mosque	mosque
1f54d	synagogue	synagogue
1f54e	menorah	branches menorah nine with
1f557	time	clock8 eight oclock clock
1f56f	candle	candle
1f570	mantelpiece_clock	clock mantelpiece
1f573	hole	hole
1f574	levitating	business in levitating man person suit hover
1f575	detective	detective or sleuth spy agent sneaky
1f576	dark_sunglasses	dark sunglasses
1f577	spider	spider
1f578	web	spider web
1f579	joystick	joystick arcade
1f57a	dancing	dancing man disco
1f587	office_supplies	linked paperclips paperclip chain
1f58a	pen	ballpoint left lower pen
1f58b	fountain_pen	fountain left lower pen
1f58c	paintbrush	left lower paintbrush
1f58d	crayon	crayon left lower
1f590	high_five	fingers hand raised splayed with palm
1f595	middle_finger	extended finger fu hand middle reversed with
1f596	spock	and between fingers hand middle part raised ring salute vulcan with live long prosper
1f5a4	black_heart	black heart
1f5a5	desktop_computer	computer desktop
1f5a8	printer	printer
1f5b1	computer_mouse	button computer mouse three
1f5b2	trackball	trackball
1f5bc	picture	frame framed picture with
1f5c2	sort	card dividers index
1f5c3	archive	box card file
1f5c4	file_cabinet	cabinet file
1f5d1	wastebasket	wastebasket trash can
1f5d2	spiral_notepad	note notepad pad spiral
1f5d3	spiral_calendar	calendar pad spiral
1f5dc	compression	clamp compression vise
1f5dd	secret	key old dungeon encrypted clue hint
1f5de	newspaper	newspaper roll rolled up swat
1f5e1	dagger	dagger knife rated for violence
1f5e3	speaking_head	head in silhouette speaking
1f5e8	speech_bubble	bubble left speech
1f5ef	anger_bubble	anger bubble right
1f5f3	ballot_box	ballot box with
1f5fa	map	map world road trip
1f5fb	mount_fuji	fuji mount
1f5fc	tower	tokyo tower
1f5fd	statue	liberty of statue new york
1f5fe	japan	japan map of
1f5ff	rock_carving	moai moyai
1f600	grinning	face grinning happy
1f601	grinning_face_with_smiling_eyes	beaming eyes face grin smiling with
1f602	joy	face joy of tears with laughter
1f603	smiley	big eyes face grinning smiley with
1f604	smile	eyes face grinning smile smiling with
1f605	sweat_smile	face grinning smile sweat with
1f606	laughing	face grinning laughing satisfied squinting lol
1f607	innocent	face halo innocent smiling with
1f608	smiling_devil	face horns imp smiling with
1f609	wink	face wink winking
1f60a	blush	blush eyes face smiling with
1f60b	yum	face food savoring yum
1f60c	relieved	face relieved
1f60d	heart_eyes	eyes face heart smiling with in love
1f60e	sunglasses	face smiling sunglasses with
1f60f	smirk	face smirk smirking smug
1f610	neutral	face neutral
1f611	expressionless	expressionless face
1f612	unamused	face unamused
1f613	sweat	downcast face sweat with
1f614	pensive	face pensive tired
1f615	oh_no	confused face half frown concerned
1f616	confounded	confounded face agony
1f617	kissing_face	face kissing smooch smooches
1f618	heart_kiss	a blowing face heart kiss kissing blow
1f619	kiss_smiling_eyes	eyes face kissing smiling with
1f61a	kiss_with_blush	closed eyes face kissing with
1f61b	stuck_out_tongue	face out stuck tongue with mischievous
1f61c	stuck_out_tongue_wink	eye face out stuck tongue winking with joking crazy
1f61d	stuck_out_tongue_closed_eyes	closed eyes face out squinting stuck tongue with
1f61e	disappointed	disappointed face
1f61f	worried	face worried
1f620	angry	angry face
1f621	rage	enraged face pout rage mad grumpy very angry
1f622	cry	cry crying face
1f623	persevere	face persevere persevering helpless
1f624	triumph	face from nose steam triumph with
1f625	exhausted	but disappointed face relieved sad stressed
1f626	frowning	face frowning mouth open with
1f627	anguished	anguished face pained
1f628	fear	face fearful scared shock
1f629	weary	face weary distraught
1f62a	sleepy	face sleepy
1f62b	anguish	face tired
1f62c	grimacing	face grimacing nervous anxious
1f62d	sob	crying face loudly sob
1f62e	open_mouth	face mouth open with surprise
1f62f	hushed	face hushed
1f630	cold_sweat	anxious cold face sweat with
1f631	scream	face fear in scream screaming
1f632	astonished	astonished face
1f633	flushed	face flushed embarrassed blushing
1f634	sleeping	face sleeping
1f635	dizzy	crossed dizzy eyes face knocked out with
1f636	speechless	face mouth no without blank poker
1f637	mask	face mask medical with
1f638	smile_cat	cat eyes grinning smile smiling with
1f639	joy_cat	cat joy of tears with
1f63a	smiley_cat	cat grinning smiley
1f63b	heart_eyes_cat	cat eyes heart smiling with
1f63c	smirk_cat	cat smile smirk with wry smug
1f63d	kissing_cat	cat kissing
1f63e	angry_cat	cat pouting
1f63f	crying_cat	cat crying face
1f640	scream_cat	cat scream weary
1f641	frown	face frowning slightly slight frown
1f642	slight_smile	face slightly smiling
1f643	upside_down	down face upside oops
1f644	rolling_eyes	eyes face roll rolling with
1f645	no_signal	gesturing good no person nope
1f646	ok_signal	gesturing ok person
1f647	bow	bow bowing person
1f648	see_no_evil	evil monkey no see
1f649	hear_no_evil	evil hear monkey no
1f64a	speak_no_evil	evil monkey no speak
1f64b	raising_hand	hand person raising pick me
1f64c	raised_hands	hands raised raising praise
1f64d	person_frowning	frowning person
1f64e	person_pouting	face person pouting with
1f64f	folded_hands	folded hands pray welcome thank you namaste
1f680	rocket	rocket
1f681	helicopter	helicopter
1f682	train	locomotive steam
1f683	railway_car	car railway train
1f684	high_speed_train	bullettrain high side speed train
1f685	bullet_train	bullet bullettrain front train
1f686	oncoming_train	train train2
1f687	subway	metro
1f688	light_rail	light rail
1f689	station	station
1f68a	oncoming_tram	tram oncoming streetcar trolley
1f68b	tram	car train tram streetcar
1f68c	bus	bus school
1f68d	oncoming_bus	bus oncoming
1f68e	trolley	trolleybus
1f68f	bus_stop	bus busstop stop
1f690	minibus	minibus
1f691	ambulance	ambulance
1f692	fire_truck	engine fire
1f693	police_car	car police
1f694	oncoming_police_car	car oncoming police
1f695	taxi	taxi rideshare
1f696	oncoming_taxi	oncoming taxi
1f697	car	automobile car red
1f698	oncoming_car	automobile oncoming
1f699	recreational_vehicle	blue car sport utility vehicle jeep
1f69a	moving_truck	delivery truck
1f69b	truck	articulated lorry tractor-trailer big rig semi truck transport
1f69c	tractor	tractor
1f69d	monorail	monorail elevated train
1f69e	mountain_railway	mountain railway
1f69f	suspension_railway	railway suspension
1f6a0	gondola	cableway mountain
1f6a1	aerial_tramway	aerial tramway ski lift
1f6a2	ship	ship
1f6a3	rowboat	boat person rowboat rowing crew sculling
1f6a4	speedboat	speedboat
1f6a5	horizontal_traffic_light	horizontal light traffic
1f6a6	traffic_light	light traffic vertical
1f6a7	work_in_progress	construction zone
1f6a8	siren	car light police rotating alert
1f6a9	triangular_flag	flag on post triangular
1f6aa	door	door
1f6ab	prohibited	entry no prohibited sign not allowed
1f6ac	smoking	cigarette smoking
1f6ad	no_smoking	no smoking
1f6ae	put_litter_in_its_place	bin in its litter place put sign
1f6af	do_not_litter	do litter littering no not
1f6b0	potable_water	potable water tap drinking
1f6b1	non-potable_water	non potable water
1f6b2	bike	bicycle bike
1f6b3	no_bicycles	bicycles no
1f6b4	cyclist	bicyclist biking person
1f6b5	mountain_biker	bicyclist biking mountain person
1f6b6	walking	person walking pedestrian
1f6b7	no_pedestrians	no pedestrians
1f6b8	children_crossing	children crossing school drive with care
1f6b9	mens	mens room
1f6ba	womens	room womens
1f6bb	restroom	restroom
1f6bc	baby_change_station	baby symbol nursery
1f6bd	toilet	toilet
1f6be	wc	closet water wc
1f6bf	shower	shower
1f6c0	bath	bath person taking
1f6c1	bathtub	bathtub
1f6c2	passport_control	control passport immigration
1f6c3	customs	customs
1f6c4	baggage_claim	baggage claim
1f6c5	locker	left luggage locked bag
1f6cb	living_room	and couch lamp furniture lifestyles
1f6cc	in_bed	accommodation bed in person sleeping accommodations guestrooms
1f6cd	shopping_bags	bags shopping
1f6ce	bellhop_bell	bell bellhop reception services ding
1f6cf	bed	bed bedroom
1f6d0	place_of_worship	of place worship
1f6d1	stop_sign	sign stop octagonal
1f6d2	shopping_cart	cart shopping trolley
1f6d5	hindu_temple	hindu temple
1f6d6	hut	hut roundhouse shelter yurt
1f6d7	elevator	elevator hoist
1f6e0	working_on_it	and hammer wrench tools
1f6e1	shield	shield
1f6e2	oil_drum	drum oil commodities
1f6e3	road	motorway
1f6e4	railway_track	railway track train tracks
1f6e5	motor_boat	boat motor
1f6e9	small_airplane	airplane small
1f6eb	take_off	airplane departure flight
1f6ec	landing	airplane arrival arriving flight
1f6f0	satellite	artificial satellite
1f6f3	passenger_ship	passenger ship yacht cruise
1f6f4	kick_scooter	kick scooter
1f6f5	scooter	motor scooter bike
1f6f6	canoe	canoe
1f6f7	sled	sled luge sledge sleigh toboggan
1f6f8	flying_saucer	flying saucer aliens extra terrestrial
1f6f9	skateboard	skateboard board skater wheels
1f6fa	auto_rickshaw	auto rickshaw tuk
1f6fb	pickup_truck	pickup truck automobile flatbed pick up transportation
1f6fc	roller_skate	roller skate blades skates
1f7e0	orange_circle	circle orange
1f7e1	yellow_circle	circle yellow
1f7e2	green_circle	circle green
1f7e3	purple_circle	circle purple
1f7e4	brown_circle	brown circle
1f7e5	red_square	red square penalty
1f7e6	blue_square	blue square
1f7e7	orange_square	orange square
1f7e8	yellow_large_square	square yellow
1f7e9	green_large_square	green square
1f7ea	purple_square	purple square
1f7eb	brown_square	brown square
1f90c	pinched_fingers	fingers pinched huh interrogation patience ugh zip
1f90d	white_heart	heart white
1f90e	brown_heart	brown heart
1f90f	pinching_hand	hand pinching amount bit little
1f910	silence	face mouth zipper quiet hush zip it lips are sealed
1f911	money_face	face money mouth kaching
1f912	sick	face thermometer with flu ill fever
1f913	nerd	face nerd geek
1f914	thinking	face thinking
1f915	hurt	bandage face head with injured
1f916	robot	face robot
1f917	hug	face hands hugging hugs open smiling with arms
1f918	rock_on	horns metal of sign the
1f919	call_me	call hand me
1f91a	stop	back hand of raised
1f91b	left_fist	facing fist left
1f91c	right_fist	facing fist right
1f91d	handshake	handshake done deal
1f91e	fingers_crossed	crossed fingers
1f91f	love_you_gesture	gesture love you
1f920	cowboy	cowboy face hat
1f921	clown	clown face
1f922	nauseated	face nauseated queasy
1f923	rolling_on_the_floor_laughing	floor laughing on rofl rolling the
1f924	drooling	drooling face
1f925	lying	face lying
1f926	face_palm	facepalm facepalming person
1f927	sneezing	face sneezing
1f928	face_with_raised_eyebrow	eyebrow face raised with disapproval distrust emoji hmm mild skeptic skepticism
1f929	star_struck	star struck starry eyed
1f92a	zany_face	face zany goofy
1f92b	shushing_face	face shushing shh shush
1f92c	face_with_symbols_on_mouth	cursing face mouth on symbols with censor cussing pissed swearing
1f92d	face_with_hand_over_mouth	face hand mouth over with giggle giggling realization sudden whoops
1f92e	face_vomiting	face vomiting barf ew gross puke spew vomit
1f92f	exploding_head	exploding head blown explode mind mindblown shocked way
1f930	pregnant	pregnant woman expecting
1f931	breast_feeding	breast feeding
1f932	palms_up_together	palms together up cupped dua prayer
1f933	selfie	selfie
1f934	prince	prince
1f935	tuxedo	in person tuxedo
1f936	mother_christmas	claus mrs
1f937	shrug	person shrug shrugging
1f938	cartwheel	cartwheeling person acrobatics gymnastics tumbling
1f939	juggling	juggling person
1f93a	fencing	fencing person
1f93c	wrestling	people wrestling
1f93d	water_polo	person playing polo water
1f93e	handball	handball person playing
1f93f	diving_mask	diving mask snorkeling
1f940	wilted_flower	flower wilted crushed
1f941	drum	drum
1f942	clink	clinking glasses toast
1f943	small_glass	glass tumbler
1f944	spoon	spoon
1f945	gooooooooal	goal net
1f947	first_place	1st medal place gold number one
1f948	second_place	2nd medal place silver
1f949	third_place	3rd medal place bronze
1f94a	boxing_glove	boxing glove
1f94b	black_belt	arts martial uniform keikogi dogi
1f94c	curling_stone	curling stone
1f94d	lacrosse	lacrosse
1f94e	softball	softball glove underarm
1f94f	flying_disc	disc flying ultimate
1f950	croissant	croissant
1f951	avocado	avocado
1f952	cucumber	cucumber
1f953	bacon	bacon
1f954	potato	potato
1f955	carrot	carrot
1f956	baguette	baguette bread
1f957	salad	green salad
1f958	paella	food of pan shallow
1f959	doner_kebab	flatbread stuffed shawarma souvlaki
1f95a	egg	egg egg2
1f95b	milk	glass milk of
1f95c	peanuts	peanuts
1f95d	kiwi	fruit kiwi
1f95e	pancakes	pancakes breakfast
1f95f	dumpling	dumpling empanada gyōza jiaozi pierogi potsticker gyoza
1f960	fortune_cookie	cookie fortune prophecy
1f961	takeout_box	box takeout delivery
1f962	chopsticks	chopsticks hashi jeotgarak kuaizi
1f963	bowl_with_spoon	bowl spoon with cereal congee oatmeal porridge
1f964	cup_with_straw	cup straw with malt soda soft
1f965	coconut	coconut colada piña pina
1f966	broccoli	broccoli wild
1f967	pie	pie filling pastry slice
1f968	pretzel	pretzel convoluted twisted
1f969	cut_of_meat	cut meat of lambchop porkchop steak
1f96a	sandwich	sandwich
1f96b	canned_food	canned food can
1f96c	leafy_green	green leafy bok burgers choy kale lettuce
1f96d	mango	mango
1f96e	moon_cake	cake moon autumn festival yuèbǐng yuebing
1f96f	bagel	bagel schmear
1f970	smiling_face_with_hearts	face hearts smiling three with 3 adore crush
1f971	yawning_face	face yawning bedtime nap sleep yawn
1f972	smiling_face_with_tear	face smiling tear with glad pain touched
1f973	partying_face	face partying bday hooray
1f974	woozy_face	face woozy drunk intoxicated tipsy uneven wavy
1f975	hot_face	face hot dying feverish panting red faced stroke sweating
1f976	cold_face	cold face blue faced freezing frostbite icicles subzero
1f977	ninja	ninja assassin fight fighter skills stealth
1f978	disguised_face	disguised face disguise incognito moustache mustache tache tash
1f97a	pleading_face	face pleading begging big mercy why
1f97b	sari	sari
1f97c	lab_coat	coat lab clothes dr
1f97d	goggles	goggles dive welding
1f97e	hiking_boot	boot hiking backpacking outdoors
1f97f	flat_shoe	flat shoe comfy flats slip on slipper
1f980	crab	crab
1f981	lion	face lion
1f982	scorpion	scorpion
1f983	turkey	turkey
1f984	unicorn	face unicorn
1f985	eagle	eagle
1f986	duck	duck
1f987	bat	bat
1f988	shark	shark
1f989	owl	owl
1f98a	fox	face fox
1f98b	butterfly	butterfly
1f98c	deer	deer
1f98d	gorilla	gorilla harambe
1f98e	lizard	lizard gecko
1f98f	rhinoceros	rhinoceros
1f990	shrimp	shrimp
1f991	squid	squid
1f992	giraffe	giraffe spots
1f993	zebra	zebra stripe
1f994	hedgehog	hedgehog spiny
1f995	sauropod	sauropod brachiosaurus brontosaurus diplodocus
1f996	t_rex	rex t tyrannosaurus
1f997	cricket	cricket grasshopper orthoptera
1f998	kangaroo	kangaroo joey jump marsupial
1f999	llama	llama alpaca guanaco vicuña wool vicuna
1f99a	peacock	peacock colorful ostentatious peahen
1f99b	hippopotamus	hippopotamus hippo
1f99c	parrot	parrot talk
1f99d	raccoon	raccoon curious
1f99e	lobster	lobster bisque claws seafood
1f99f	mosquito	mosquito malaria
1f9a0	microbe	microbe amoeba
1f9a1	badger	badger pester
1f9a2	swan	swan cygnet duckling ugly
1f9a3	mammoth	mammoth tusk wooly
1f9a4	dodo	dodo
1f9a5	sloth	sloth lazy slow
1f9a6	otter	otter playful
1f9a7	orangutan	orangutan ape
1f9a8	skunk	skunk stink
1f9a9	flamingo	flamingo flamboyant
1f9aa	oyster	oyster
1f9ab	beaver	beaver dam
1f9ac	bison	bison buffalo herd wisent
1f9ad	seal	seal
1f9ae	guide_dog	dog guide
1f9af	white_cane	cane probing white
1f9b4	bone	bone wishbone
1f9b5	leg	leg knee limb
1f9b6	foot	foot ankle stomp
1f9b7	tooth	tooth dentist pearly
1f9b8	superhero	superhero
1f9b9	supervillain	supervillain
1f9ba	safety_vest	safety vest emergency
1f9bb	ear_with_hearing_aid	aid ear hearing with hard
1f9bc	motorized_wheelchair	motorized wheelchair
1f9bd	manual_wheelchair	manual wheelchair
1f9be	mechanical_arm	arm mechanical
1f9bf	mechanical_leg	leg mechanical
1f9c0	cheese	cheese wedge
1f9c1	cupcake	cupcake dessert sprinkles sugar treat
1f9c2	salt	salt flavor salty taste
1f9c3	beverage_box	beverage box
1f9c4	garlic	garlic
1f9c5	onion	onion
1f9c6	falafel	falafel chickpea meatball
1f9c7	waffle	waffle indecisive iron
1f9c8	butter	butter dairy
1f9c9	mate	mate
1f9ca	ice	cube ice iceberg
1f9cb	bubble_tea	bubble tea boba
1f9cd	person_standing	person standing
1f9ce	person_kneeling	kneeling person
1f9cf	deaf_person	deaf person
1f9d0	face_with_monocle	face monocle with classy fancy stuffy wealthy
1f9d1	person	adult person
1f9d2	child	child bright eyed grandchild kid young younger
1f9d3	older_person	adult older person elderly grandparent old wise
1f9d4	person_beard	beard bearded person
1f9d5	woman_with_headscarf	headscarf with woman bandana hijab kerchief mantilla tichel
1f9d6	person_in_steamy_room	in person room sauna steamy
1f9d7	person_climbing	climbing person
1f9d8	person_in_lotus_position	in lotus person position
1f9d9	mage	mage
1f9da	fairy	fairy
1f9db	vampire	vampire dracula
1f9dc	merperson	merperson
1f9dd	elf	elf
1f9de	genie	genie
1f9df	zombie	zombie
1f9e0	brain	brain intelligent smart
1f9e1	orange_heart	heart orange
1f9e2	billed_cap	billed cap
1f9e3	scarf	scarf neck
1f9e4	gloves	gloves
1f9e5	coat	coat brr
1f9e6	socks	socks stocking
1f9e7	red_envelope	envelope red hóngbāo lai see hongbao
1f9e8	firecracker	firecracker dynamite explosive pop popping spark
1f9e9	puzzle_piece	jigsaw piece puzzle interlocking
1f9ea	test_tube	test tube chemistry
1f9eb	petri_dish	dish petri biology culture
1f9ec	dna	dna evolution gene genetics
1f9ed	compass	compass direction navigation orienteering
1f9ee	abacus	abacus calculation calculator
1f9ef	fire_extinguisher	extinguisher fire extinguish quench
1f9f0	toolbox	toolbox chest
1f9f1	brick	brick bricks clay mortar wall
1f9f2	magnet	magnet attraction horseshoe negative positive shape u
1f9f3	luggage	luggage bag packing suitcase travel
1f9f4	lotion_bottle	bottle lotion moisturizer shampoo sunscreen
1f9f5	thread	thread spool string
1f9f6	yarn	yarn crochet knit
1f9f7	safety_pin	pin safety diaper punk
1f9f8	teddy_bear	bear teddy plaything plush
1f9f9	broom	broom sweeping
1f9fa	basket	basket farming laundry picnic
1f9fb	roll_of_paper	of paper roll towels
1f9fc	soap	soap bar lather soapdish
1f9fd	sponge	sponge absorbing porous soak
1f9fe	receipt	receipt accounting bookkeeping evidence invoice proof
1f9ff	nazar_amulet	amulet nazar bead charm evil eye talisman
1fa70	ballet_shoes	ballet shoes
1fa71	one_piece_swimsuit	one piece swimsuit
1fa72	briefs	brief briefs swim
1fa73	shorts	shorts pants
1fa74	thong_sandal	sandal thong flop sandals thongs zōri zori
1fa78	drop_of_blood	blood drop of bleed donation injury menstruation
1fa79	adhesive_bandage	adhesive bandage
1fa7a	stethoscope	stethoscope
1fa80	yo_yo	yo fluctuate
1fa81	kite	kite
1fa82	parachute	parachute hang glide parasail skydive
1fa83	boomerang	boomerang rebound repercussion weapon
1fa84	magic_wand	magic wand magician
1fa85	piñata	pinata cinco de festive mayo pinada
1fa86	nesting_dolls	dolls nesting babooshka baboushka babushka doll matryoshka russia
1fa90	ringed_planet	planet ringed saturn saturnine
1fa91	chair	chair sit
1fa92	razor	razor sharp shave
1fa93	axe	axe ax hatchet split
1fa94	diya_lamp	diya lamp oil
1fa95	banjo	banjo stringed
1fa96	military_helmet	helmet military army warrior
1fa97	accordion	accordion concertina squeeze squeezebox
1fa98	long_drum	drum long conga rhythm
1fa99	coin	coin dollar euro metal
1fa9a	carpentry_saw	carpentry saw carpenter trim
1fa9b	screwdriver	screwdriver flathead handy
1fa9c	ladder	ladder rung step
1fa9d	hook	hook crook curve ensnare point selling
1fa9e	mirror	mirror makeup reflection reflector speculum
1fa9f	window	window air frame fresh opening transparent view
1faa0	plunger	plunger force suction
1faa1	sewing_needle	needle sewing embroidery sew stitches sutures tailoring
1faa2	knot	knot cord rope tangled twine twist
1faa3	bucket	bucket cask vat
1faa4	mouse_trap	mouse trap bait lure mousetrap snare
1faa5	toothbrush	toothbrush bathroom brush dental hygiene toiletry
1faa6	headstone	headstone cemetery graveyard memorial rip tomb tombstone
1faa7	placard	placard demonstration notice picket plaque protest
1faa8	rock	rock boulder solid tough
1fab0	fly	fly maggot rotting
1fab1	worm	worm annelid earthworm parasite
1fab2	beetle	beetle
1fab3	cockroach	cockroach roach
1fab4	potted_plant	plant potted decor grow nurturing
1fab5	wood	wood log timber
1fab6	feather	feather flight plumage
1fac0	anatomical_heart	anatomical heart cardiology pulse real
1fac1	lungs	lungs breath breathe exhalation inhalation lung respiration
1fac2	people_hugging	hugging people comfort embrace farewell friendship goodbye thanks
1fad0	blueberries	blueberries berries berry bilberry blueberry
1fad1	bell_pepper	bell pepper capsicum
1fad2	olive	olive
1fad3	flatbread	flatbread arepa gordita lavash naan pita
1fad4	tamale	tamale mexican pamonha wrapped
1fad5	fondue	fondue melted
1fad6	teapot	teapot brew
"""#
}
