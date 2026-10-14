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
23-20e3	hash	hash
2a-20e3	asterisk	asterisk
30-20e3	zero	0 keycap zero
31-20e3	one	1 keycap one
32-20e3	two	2 keycap two
33-20e3	three	3 keycap three
34-20e3	four	4 four keycap
35-20e3	five	5 five keycap
36-20e3	six	6 keycap six
37-20e3	seven	7 keycap seven
38-20e3	eight	8 eight keycap
39-20e3	nine	9 keycap nine
a9	copyright	copyright
ae	registered	registered
203c	bangbang	bangbang double exclamation mark
2049	interrobang	exclamation interrobang mark question
2122	tm	mark tm trade
2139	information_source	information source
2194	left_right_arrow	arrow left right
2195	arrow_up_down	arrow down up
2196	arrow_upper_left	arrow left up upper
2197	arrow_upper_right	arrow right up upper
2198	arrow_lower_right	arrow down lower right
2199	arrow_lower_left	arrow down left lower
21a9	leftwards_arrow_with_hook	arrow curving hook left leftwards right with
21aa	arrow_right_hook	arrow curving hook left right
231a	watch	watch
231b	hourglass	done hourglass
2328	keyboard	keyboard
23cf	eject_symbol	button eject symbol
23e9	fast_forward	button fast forward
23ea	rewind	button fast reverse rewind
23eb	arrow_double_up	arrow button double fast up
23ec	arrow_double_down	arrow button double down fast
23ed	black_right_pointing_double_triangle_with_vertical_bar	bar black button double next pointing right track triangle vertical with
23ee	previous_track_button	bar black button double last left pointing previous track triangle vertical with
23ef	black_right_pointing_triangle_with_double_vertical_bar	bar black button double or pause play pointing right triangle vertical with
23f0	alarm_clock	alarm clock
23f1	stopwatch	stopwatch
23f2	timer_clock	clock timer
23f3	hourglass_flowing_sand	done flowing hourglass not sand
23f8	double_vertical_bar	bar button double pause vertical
23f9	black_square_for_stop	black button for square stop
23fa	black_circle_for_record	black button circle for record
24c2	m	circled m
25aa	black_small_square	black small square
25ab	white_small_square	small square white
25b6	arrow_forward	arrow button forward play
25c0	arrow_backward	arrow backward button reverse
25fb	white_medium_square	medium square white
25fc	black_medium_square	black medium square
25fd	white_medium_small_square	medium small square white
25fe	black_medium_small_square	black medium small square
2600	sunny	sun sunny
2601	cloud	cloud
2602	open_umbrella	open umbrella
2603	snowman_with_snow	snow snowman with
2604	comet	comet
260e	phone	phone telephone
2611	ballot_box_with_check	ballot box check with
2614	umbrella	drops rain umbrella with
2615	coffee	beverage coffee hot
2618	shamrock	shamrock
261d	point_up	index point pointing up
2620	skull_and_crossbones	and crossbones skull
2622	radioactive_sign	radioactive sign
2623	biohazard_sign	biohazard sign
2626	orthodox_cross	cross orthodox
262a	star_and_crescent	and crescent star
262e	peace_symbol	peace symbol
262f	yin_yang	yang yin
2638	wheel_of_dharma	dharma of wheel
2639	white_frowning_face	face frowning white
263a	relaxed	face relaxed smiling
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
265f	chess_pawn	chess pawn
2660	spades	spade spades suit
2663	clubs	club clubs suit
2665	hearts	heart hearts suit
2666	diamonds	diamond diamonds suit
2668	hotsprings	hot hotsprings springs
267b	recycle	recycle recycling symbol
267e	infinity	infinity
267f	wheelchair	symbol wheelchair
2692	hammer_and_pick	and hammer pick
2693	anchor	anchor
2694	crossed_swords	crossed swords
2695	medical_symbol	medical symbol
2696	scales	balance scale scales
2697	alembic	alembic
2699	gear	gear
269b	atom_symbol	atom symbol
269c	fleur_de_lis	de fleur lis
26a0	warning	warning
26a1	zap	high voltage zap
26a7	transgender_symbol	symbol transgender
26aa	white_circle	circle white
26ab	black_circle	black circle
26b0	coffin	coffin
26b1	funeral_urn	funeral urn
26bd	soccer	ball soccer
26be	baseball	baseball
26c4	snowman	snow snowman without
26c5	partly_sunny	behind cloud partly sun sunny
26c8	thunder_cloud_and_rain	and cloud lightning rain thunder with
26ce	ophiuchus	ophiuchus
26cf	pick	pick
26d1	helmet_with_white_cross	cross helmet rescue white with worker workers
26d3	chains	chains
26d4	no_entry	entry no
26e9	shinto_shrine	shinto shrine
26ea	church	church
26f0	mountain	mountain
26f1	parasol_on_ground	ground on parasol umbrella
26f2	fountain	fountain
26f3	golf	flag golf hole in
26f4	ferry	ferry
26f5	boat	boat sailboat
26f7	skier	skier
26f8	ice_skate	ice skate
26f9	bouncing_ball_person	ball bouncing person with
26fa	tent	tent
26fd	fuelpump	fuel fuelpump pump
2702	scissors	scissors
2705	white_check_mark	button check mark white
2708	airplane	airplane
2709	envelope	envelope
270a	fist	fist raised
270b	hand	hand raised
270c	v	hand v victory
270d	writing_hand	hand writing
270f	pencil2	pencil pencil2
2712	black_nib	black nib
2714	heavy_check_mark	check heavy mark
2716	heavy_multiplication_x	heavy multiplication multiply x
271d	latin_cross	cross latin
2721	star_of_david	david of star
2728	sparkles	sparkles
2733	eight_spoked_asterisk	asterisk eight spoked
2734	eight_pointed_black_star	black eight pointed star
2744	snowflake	snowflake
2747	sparkle	sparkle
274c	x	cross mark x
274e	negative_squared_cross_mark	button cross mark negative squared
2753	question	mark question red
2754	grey_question	grey mark question white
2755	grey_exclamation	exclamation grey mark white
2757	heavy_exclamation_mark	exclamation heavy mark red
2763	heavy_heart_exclamation	exclamation heart heavy mark ornament
2764	heart	heart red
2795	heavy_plus_sign	heavy plus sign
2796	heavy_minus_sign	heavy minus sign
2797	heavy_division_sign	divide division heavy sign
27a1	arrow_right	arrow right
27b0	curly_loop	curly loop
27bf	loop	curly double loop
2934	arrow_heading_up	arrow curving heading right up
2935	arrow_heading_down	arrow curving down heading right
2b05	arrow_left	arrow left
2b06	arrow_up	arrow up
2b07	arrow_down	arrow down
2b1b	black_large_square	black large square
2b1c	white_large_square	large square white
2b50	star	star
2b55	o	circle hollow o red
3030	wavy_dash	dash wavy
303d	part_alternation_mark	alternation mark part
3297	congratulations	button congratulations japanese
3299	secret	button japanese secret
1f004	mahjong	dragon mahjong red
1f0cf	black_joker	black joker
1f170	a	a blood button type
1f171	b	b blood button type
1f17e	o2	blood button o o2 type
1f17f	parking	button p parking
1f18e	ab	ab blood button type
1f191	cl	button cl
1f192	cool	button cool
1f193	free	button free
1f194	id	button id
1f195	new	button new
1f196	ng	button ng
1f197	ok	button ok
1f198	sos	button sos
1f199	up	button up
1f19a	vs	button vs
1f201	koko	button here japanese koko
1f202	sa	button charge japanese sa service
1f21a	u7121	button charge free japanese of u7121
1f22f	u6307	button japanese reserved u6307
1f232	u7981	button japanese prohibited u7981
1f233	u7a7a	button japanese u7a7a vacancy
1f234	u5408	button grade japanese passing u5408
1f235	u6e80	button japanese no u6e80 vacancy
1f236	u6709	button charge free japanese not of u6709
1f237	u6708	amount button japanese monthly u6708
1f238	u7533	application button japanese u7533
1f239	u5272	button discount japanese u5272
1f23a	u55b6	business button for japanese open u55b6
1f250	ideograph_advantage	advantage bargain button ideograph japanese
1f251	accept	accept acceptable button japanese
1f300	cyclone	cyclone
1f301	foggy	foggy
1f302	closed_umbrella	closed umbrella
1f303	night_with_stars	night stars with
1f304	sunrise_over_mountains	mountains over sunrise
1f305	sunrise	sunrise
1f306	city_sunset	at city cityscape dusk sunset
1f307	city_sunrise	city sunrise sunset
1f308	rainbow	rainbow
1f309	bridge_at_night	at bridge night
1f30a	ocean	ocean water wave
1f30b	volcano	volcano
1f30c	milky_way	milky way
1f30d	earth_africa	africa earth europe globe showing
1f30e	earth_americas	americas earth globe showing
1f30f	earth_asia	asia australia earth globe showing
1f310	globe_with_meridians	globe meridians with
1f311	new_moon	moon new
1f312	waxing_crescent_moon	crescent moon waxing
1f313	first_quarter_moon	first moon quarter
1f314	moon	gibbous moon waxing
1f315	full_moon	full moon
1f316	waning_gibbous_moon	gibbous moon waning
1f317	last_quarter_moon	last moon quarter
1f318	waning_crescent_moon	crescent moon waning
1f319	crescent_moon	crescent moon
1f31a	new_moon_with_face	face moon new with
1f31b	first_quarter_moon_with_face	face first moon quarter with
1f31c	last_quarter_moon_with_face	face last moon quarter with
1f31d	full_moon_with_face	face full moon with
1f31e	sun_with_face	face sun with
1f31f	star2	glowing star star2
1f320	stars	shooting star stars
1f321	thermometer	thermometer
1f324	white_sun_with_small_cloud	behind cloud small sun white with
1f325	white_sun_behind_cloud	behind cloud large sun white
1f326	white_sun_behind_cloud_with_rain	behind cloud rain sun white with
1f327	cloud_with_rain	cloud rain with
1f328	cloud_with_snow	cloud snow with
1f329	cloud_with_lightning	cloud lightning with
1f32a	cloud_with_tornado	cloud tornado with
1f32b	fog	fog
1f32c	wind_blowing_face	blowing face wind
1f32d	hotdog	dog hot hotdog
1f32e	taco	taco
1f32f	burrito	burrito
1f330	chestnut	chestnut
1f331	seedling	seedling
1f332	evergreen_tree	evergreen tree
1f333	deciduous_tree	deciduous tree
1f334	palm_tree	palm tree
1f335	cactus	cactus
1f336	hot_pepper	hot pepper
1f337	tulip	tulip
1f338	cherry_blossom	blossom cherry
1f339	rose	rose
1f33a	hibiscus	hibiscus
1f33b	sunflower	sunflower
1f33c	blossom	blossom
1f33d	corn	corn ear of
1f33e	ear_of_rice	ear of rice sheaf
1f33f	herb	herb
1f340	four_leaf_clover	clover four leaf
1f341	maple_leaf	leaf maple
1f342	fallen_leaf	fallen leaf
1f343	leaves	fluttering in leaf leaves wind
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
1f356	meat_on_bone	bone meat on
1f357	poultry_leg	leg poultry
1f358	rice_cracker	cracker rice
1f359	rice_ball	ball rice
1f35a	rice	cooked rice
1f35b	curry	curry rice
1f35c	ramen	bowl ramen steaming
1f35d	spaghetti	spaghetti
1f35e	bread	bread
1f35f	fries	french fries
1f360	sweet_potato	potato roasted sweet
1f361	dango	dango
1f362	oden	oden
1f363	sushi	sushi
1f364	fried_shrimp	fried shrimp
1f365	fish_cake	cake fish swirl with
1f366	icecream	cream ice icecream soft
1f367	shaved_ice	ice shaved
1f368	ice_cream	cream ice
1f369	doughnut	doughnut
1f36a	cookie	cookie
1f36b	chocolate_bar	bar chocolate
1f36c	candy	candy
1f36d	lollipop	lollipop
1f36e	custard	custard
1f36f	honey_pot	honey pot
1f370	cake	cake shortcake
1f371	bento	bento box
1f372	stew	food of pot stew
1f373	egg	cooking egg fried
1f374	fork_and_knife	and fork knife
1f375	tea	handle tea teacup without
1f376	sake	sake
1f377	wine_glass	glass wine
1f378	cocktail	cocktail glass
1f379	tropical_drink	drink tropical
1f37a	beer	beer mug
1f37b	beers	beer beers clinking mugs
1f37c	baby_bottle	baby bottle
1f37d	plate_with_cutlery	and cutlery fork knife plate with
1f37e	champagne	bottle champagne cork popping with
1f37f	popcorn	popcorn
1f380	ribbon	ribbon
1f381	gift	gift wrapped
1f382	birthday	birthday cake
1f383	jack_o_lantern	jack lantern o
1f384	christmas_tree	christmas tree
1f385	santa	claus santa
1f386	fireworks	fireworks
1f387	sparkler	sparkler
1f388	balloon	balloon
1f389	tada	party popper tada
1f38a	confetti_ball	ball confetti
1f38b	tanabata_tree	tanabata tree
1f38c	crossed_flags	crossed flags
1f38d	bamboo	bamboo decoration pine
1f38e	dolls	dolls japanese
1f38f	flags	carp flags streamer
1f390	wind_chime	chime wind
1f391	rice_scene	ceremony moon rice scene viewing
1f392	school_satchel	backpack satchel school
1f393	mortar_board	board cap graduation mortar
1f396	medal_military	medal military
1f397	reminder_ribbon	reminder ribbon
1f399	studio_microphone	microphone studio
1f39a	level_slider	level slider
1f39b	control_knobs	control knobs
1f39e	film_strip	film frames strip
1f39f	tickets	admission tickets
1f3a0	carousel_horse	carousel horse
1f3a1	ferris_wheel	ferris wheel
1f3a2	roller_coaster	coaster roller
1f3a3	fishing_pole_and_fish	and fish fishing pole
1f3a4	microphone	microphone
1f3a5	movie_camera	camera movie
1f3a6	cinema	cinema
1f3a7	headphones	headphone headphones
1f3a8	art	art artist palette
1f3a9	tophat	hat top tophat
1f3aa	circus_tent	circus tent
1f3ab	ticket	ticket
1f3ac	clapper	board clapper
1f3ad	performing_arts	arts performing
1f3ae	video_game	game video
1f3af	dart	bullseye dart
1f3b0	slot_machine	machine slot
1f3b1	8ball	8 8ball ball pool
1f3b2	game_die	die game
1f3b3	bowling	bowling
1f3b4	flower_playing_cards	cards flower playing
1f3b5	musical_note	musical note
1f3b6	notes	musical notes
1f3b7	saxophone	saxophone
1f3b8	guitar	guitar
1f3b9	musical_keyboard	keyboard musical
1f3ba	trumpet	trumpet
1f3bb	violin	violin
1f3bc	musical_score	musical score
1f3bd	running_shirt_with_sash	running sash shirt with
1f3be	tennis	tennis
1f3bf	ski	ski skis
1f3c0	basketball	basketball
1f3c1	checkered_flag	checkered chequered flag
1f3c2	snowboarder	snowboarder
1f3c3	runner	person runner running
1f3c4	surfer	person surfer surfing
1f3c5	medal_sports	medal sports
1f3c6	trophy	trophy
1f3c7	horse_racing	horse racing
1f3c8	football	american football
1f3c9	rugby_football	football rugby
1f3ca	swimmer	person swimmer swimming
1f3cb	weight_lifting	lifter lifting person weight weights
1f3cc	golfing	golfer golfing person
1f3cd	racing_motorcycle	motorcycle racing
1f3ce	racing_car	car racing
1f3cf	cricket_bat_and_ball	and ball bat cricket game
1f3d0	volleyball	volleyball
1f3d1	field_hockey_stick_and_ball	and ball field hockey stick
1f3d2	ice_hockey_stick_and_puck	and hockey ice puck stick
1f3d3	table_tennis_paddle_and_ball	and ball paddle ping pong table tennis
1f3d4	mountain_snow	capped mountain snow
1f3d5	camping	camping
1f3d6	beach_umbrella	beach umbrella with
1f3d7	building_construction	building construction
1f3d8	house_buildings	buildings house houses
1f3d9	cityscape	cityscape
1f3da	derelict_house_building	building derelict house
1f3db	classical_building	building classical
1f3dc	desert	desert
1f3dd	desert_island	desert island
1f3de	national_park	national park
1f3df	stadium	stadium
1f3e0	house	house
1f3e1	house_with_garden	garden house with
1f3e2	office	building office
1f3e3	post_office	japanese office post
1f3e4	european_post_office	european office post
1f3e5	hospital	hospital
1f3e6	bank	bank
1f3e7	atm	atm sign
1f3e8	hotel	hotel
1f3e9	love_hotel	hotel love
1f3ea	convenience_store	convenience store
1f3eb	school	school
1f3ec	department_store	department store
1f3ed	factory	factory
1f3ee	izakaya_lantern	izakaya lantern paper red
1f3ef	japanese_castle	castle japanese
1f3f0	european_castle	castle european
1f3f3	waving_white_flag	flag waving white
1f3f4	waving_black_flag	black flag waving
1f3f5	rosette	rosette
1f3f7	label	label
1f3f8	badminton_racquet_and_shuttlecock	and badminton racquet shuttlecock
1f3f9	bow_and_arrow	and arrow bow
1f3fa	amphora	amphora
1f400	rat	rat
1f401	mouse2	mouse mouse2
1f402	ox	ox
1f403	water_buffalo	buffalo water
1f404	cow2	cow cow2
1f405	tiger2	tiger tiger2
1f406	leopard	leopard
1f407	rabbit2	rabbit rabbit2
1f408	cat2	cat cat2
1f409	dragon	dragon
1f40a	crocodile	crocodile
1f40b	whale2	whale whale2
1f40c	snail	snail
1f40d	snake	snake
1f40e	racehorse	horse racehorse
1f40f	ram	ram
1f410	goat	goat
1f411	sheep	ewe sheep
1f412	monkey	monkey
1f413	rooster	rooster
1f414	chicken	chicken
1f415	dog2	dog dog2
1f416	pig2	pig pig2
1f417	boar	boar
1f418	elephant	elephant
1f419	octopus	octopus
1f41a	shell	shell spiral
1f41b	bug	bug
1f41c	ant	ant
1f41d	bee	bee honeybee
1f41e	beetle	beetle lady
1f41f	fish	fish
1f420	tropical_fish	fish tropical
1f421	blowfish	blowfish
1f422	turtle	turtle
1f423	hatching_chick	chick hatching
1f424	baby_chick	baby chick
1f425	hatched_chick	baby chick facing front hatched
1f426	bird	bird
1f427	penguin	penguin
1f428	koala	koala
1f429	poodle	poodle
1f42a	dromedary_camel	camel dromedary
1f42b	camel	camel hump two
1f42c	flipper	dolphin flipper
1f42d	mouse	face mouse
1f42e	cow	cow face
1f42f	tiger	face tiger
1f430	rabbit	face rabbit
1f431	cat	cat face
1f432	dragon_face	dragon face
1f433	whale	spouting whale
1f434	horse	face horse
1f435	monkey_face	face monkey
1f436	dog	dog face
1f437	pig	face pig
1f438	frog	frog
1f439	hamster	hamster
1f43a	wolf	wolf
1f43b	bear	bear
1f43c	panda_face	face panda
1f43d	pig_nose	nose pig
1f43e	feet	feet paw prints
1f43f	chipmunk	chipmunk
1f440	eyes	eyes
1f441	eye	eye
1f442	ear	ear
1f443	nose	nose
1f444	lips	lips mouth
1f445	tongue	tongue
1f446	point_up_2	2 backhand index point pointing up
1f447	point_down	backhand down index point pointing
1f448	point_left	backhand index left point pointing
1f449	point_right	backhand index point pointing right
1f44a	fist_oncoming	facepunch fist oncoming punch
1f44b	wave	hand wave waving
1f44c	ok_hand	hand ok
1f44d	thumbs_up	1 thumbs thumbsup up
1f44e	thumbsdown	1 down thumbs thumbsdown
1f44f	clap	clap clapping hands
1f450	open_hands	hands open
1f451	crown	crown
1f452	womans_hat	hat womans
1f453	eyeglasses	eyeglasses glasses
1f454	necktie	necktie
1f455	tshirt	shirt t tshirt
1f456	jeans	jeans
1f457	dress	dress
1f458	kimono	kimono
1f459	bikini	bikini
1f45a	womans_clothes	clothes womans
1f45b	purse	purse
1f45c	handbag	handbag
1f45d	pouch	bag clutch pouch
1f45e	mans_shoe	mans shoe
1f45f	athletic_shoe	athletic running shoe
1f460	high_heel	heel heeled high shoe
1f461	sandal	sandal womans
1f462	boot	boot womans
1f463	footprints	footprints
1f464	bust_in_silhouette	bust in silhouette
1f465	busts_in_silhouette	busts in silhouette
1f466	boy	boy
1f467	girl	girl
1f468	man	man
1f469	woman	woman
1f46a	family	family
1f46b	couple	and couple hands holding man woman
1f46c	two_men_holding_hands	hands holding men two
1f46d	two_women_holding_hands	hands holding two women
1f46e	cop	cop officer police
1f46f	dancers	bunny dancers ears people with
1f470	person_with_veil	person veil with
1f471	blond_haired_person	blond hair haired person with
1f472	man_with_gua_pi_mao	gua man mao person pi skullcap with
1f473	person_with_turban	person turban wearing with
1f474	older_man	man old older
1f475	older_woman	old older woman
1f476	baby	baby
1f477	construction_worker	construction worker
1f478	princess	princess
1f479	japanese_ogre	japanese ogre
1f47a	japanese_goblin	goblin japanese
1f47b	ghost	ghost
1f47c	angel	angel baby
1f47d	alien	alien
1f47e	space_invader	alien invader monster space
1f47f	imp	angry face horns imp with
1f480	skull	skull
1f481	tipping_hand_person	desk hand information person tipping
1f482	guard	guard
1f483	dancer	dancer dancing woman
1f484	lipstick	lipstick
1f485	nail_care	care nail polish
1f486	massage	getting massage person
1f487	haircut	getting haircut person
1f488	barber	barber pole
1f489	syringe	syringe
1f48a	pill	pill
1f48b	kiss	kiss mark
1f48c	love_letter	letter love
1f48d	ring	ring
1f48e	gem	gem stone
1f48f	couplekiss	couplekiss kiss
1f490	bouquet	bouquet
1f491	couple_with_heart	couple heart with
1f492	wedding	wedding
1f493	heartbeat	beating heart heartbeat
1f494	broken_heart	broken heart
1f495	two_hearts	hearts two
1f496	sparkling_heart	heart sparkling
1f497	heartpulse	growing heart heartpulse
1f498	cupid	arrow cupid heart with
1f499	blue_heart	blue heart
1f49a	green_heart	green heart
1f49b	yellow_heart	heart yellow
1f49c	purple_heart	heart purple
1f49d	gift_heart	gift heart ribbon with
1f49e	revolving_hearts	hearts revolving
1f49f	heart_decoration	decoration heart
1f4a0	diamond_shape_with_a_dot_inside	a diamond dot inside shape with
1f4a1	bulb	bulb light
1f4a2	anger	anger symbol
1f4a3	bomb	bomb
1f4a4	zzz	zzz
1f4a5	boom	boom collision
1f4a6	sweat_drops	droplets drops sweat
1f4a7	droplet	droplet
1f4a8	dash	away dash dashing
1f4a9	poop	hankey of pile poo poop shit
1f4aa	muscle	biceps flexed muscle
1f4ab	dizzy	dizzy
1f4ac	speech_balloon	balloon speech
1f4ad	thought_balloon	balloon thought
1f4ae	white_flower	flower white
1f4af	100	100 hundred points
1f4b0	moneybag	bag money moneybag
1f4b1	currency_exchange	currency exchange
1f4b2	heavy_dollar_sign	dollar heavy sign
1f4b3	credit_card	card credit
1f4b4	yen	banknote yen
1f4b5	dollar	banknote dollar
1f4b6	euro	banknote euro
1f4b7	pound	banknote pound
1f4b8	money_with_wings	money wings with
1f4b9	chart	chart increasing with yen
1f4ba	seat	seat
1f4bb	computer	computer laptop
1f4bc	briefcase	briefcase
1f4bd	minidisc	computer disk minidisc
1f4be	floppy_disk	disk floppy
1f4bf	cd	cd disk optical
1f4c0	dvd	dvd
1f4c1	file_folder	file folder
1f4c2	open_file_folder	file folder open
1f4c3	page_with_curl	curl page with
1f4c4	page_facing_up	facing page up
1f4c5	date	calendar date
1f4c6	calendar	calendar off tear
1f4c7	card_index	card index
1f4c8	chart_with_upwards_trend	chart increasing trend upwards with
1f4c9	chart_with_downwards_trend	chart decreasing downwards trend with
1f4ca	bar_chart	bar chart
1f4cb	clipboard	clipboard
1f4cc	pushpin	pushpin
1f4cd	round_pushpin	pushpin round
1f4ce	paperclip	paperclip
1f4cf	straight_ruler	ruler straight
1f4d0	triangular_ruler	ruler triangular
1f4d1	bookmark_tabs	bookmark tabs
1f4d2	ledger	ledger
1f4d3	notebook	notebook
1f4d4	notebook_with_decorative_cover	cover decorative notebook with
1f4d5	closed_book	book closed
1f4d6	book	book open
1f4d7	green_book	book green
1f4d8	blue_book	blue book
1f4d9	orange_book	book orange
1f4da	books	books
1f4db	name_badge	badge name
1f4dc	scroll	scroll
1f4dd	pencil	memo pencil
1f4de	telephone_receiver	receiver telephone
1f4df	pager	pager
1f4e0	fax	fax machine
1f4e1	satellite	antenna satellite
1f4e2	loudspeaker	loudspeaker
1f4e3	mega	mega megaphone
1f4e4	outbox_tray	outbox tray
1f4e5	inbox_tray	inbox tray
1f4e6	package	package
1f4e7	email	e email mail
1f4e8	incoming_envelope	envelope incoming
1f4e9	envelope_with_arrow	arrow envelope with
1f4ea	mailbox_closed	closed flag lowered mailbox with
1f4eb	mailbox	closed flag mailbox raised with
1f4ec	mailbox_with_mail	flag mail mailbox open raised with
1f4ed	mailbox_with_no_mail	flag lowered mail mailbox no open with
1f4ee	postbox	postbox
1f4ef	postal_horn	horn postal
1f4f0	newspaper	newspaper
1f4f1	iphone	iphone mobile phone
1f4f2	calling	arrow calling mobile phone with
1f4f3	vibration_mode	mode vibration
1f4f4	mobile_phone_off	mobile off phone
1f4f5	no_mobile_phones	mobile no phones
1f4f6	signal_strength	antenna bars signal strength
1f4f7	camera	camera
1f4f8	camera_flash	camera flash with
1f4f9	video_camera	camera video
1f4fa	tv	television tv
1f4fb	radio	radio
1f4fc	vhs	vhs videocassette
1f4fd	film_projector	film projector
1f4ff	prayer_beads	beads prayer
1f500	twisted_rightwards_arrows	arrows button rightwards shuffle tracks twisted
1f501	repeat	button repeat
1f502	repeat_one	button one repeat single
1f503	arrows_clockwise	arrows clockwise vertical
1f504	arrows_counterclockwise	arrows button counterclockwise
1f505	low_brightness	brightness button dim low
1f506	high_brightness	bright brightness button high
1f507	mute	mute muted speaker
1f508	speaker	low speaker volume
1f509	sound	medium sound speaker volume
1f50a	loud_sound	high loud sound speaker volume
1f50b	battery	battery
1f50c	electric_plug	electric plug
1f50d	mag	glass left mag magnifying tilted
1f50e	mag_right	glass mag magnifying right tilted
1f50f	lock_with_ink_pen	ink lock locked pen with
1f510	closed_lock_with_key	closed key lock locked with
1f511	key	key
1f512	lock	lock locked
1f513	unlock	unlock unlocked
1f514	bell	bell
1f515	no_bell	bell no slash with
1f516	bookmark	bookmark
1f517	link	link
1f518	radio_button	button radio
1f519	back	arrow back
1f51a	end	arrow end
1f51b	on	arrow on on!
1f51c	soon	arrow soon
1f51d	top	arrow top
1f51e	underage	eighteen no one under underage
1f51f	ten	10 keycap ten
1f520	capital_abcd	abcd capital input latin uppercase
1f521	abcd	abcd input latin lowercase
1f522	1234	1234 input numbers
1f523	symbols	input symbols
1f524	abc	abc input latin letters
1f525	fire	fire
1f526	flashlight	flashlight
1f527	wrench	wrench
1f528	hammer	hammer
1f529	nut_and_bolt	and bolt nut
1f52a	hocho	hocho kitchen knife
1f52b	gun	gun pistol water
1f52c	microscope	microscope
1f52d	telescope	telescope
1f52e	crystal_ball	ball crystal
1f52f	six_pointed_star	dotted pointed six star
1f530	beginner	beginner for japanese symbol
1f531	trident	emblem trident
1f532	black_square_button	black button square
1f533	white_square_button	button square white
1f534	red_circle	circle red
1f535	large_blue_circle	blue circle large
1f536	large_orange_diamond	diamond large orange
1f537	large_blue_diamond	blue diamond large
1f538	small_orange_diamond	diamond orange small
1f539	small_blue_diamond	blue diamond small
1f53a	small_red_triangle	pointed red small triangle up
1f53b	small_red_triangle_down	down pointed red small triangle
1f53c	arrow_up_small	arrow button small up upwards
1f53d	arrow_down_small	arrow button down downwards small
1f549	om_symbol	om symbol
1f54a	dove_of_peace	dove of peace
1f54b	kaaba	kaaba
1f54c	mosque	mosque
1f54d	synagogue	synagogue
1f54e	menorah_with_nine_branches	branches menorah nine with
1f550	clock1	clock1 oclock one
1f551	clock2	clock2 oclock two
1f552	clock3	clock3 oclock three
1f553	clock4	clock4 four oclock
1f554	clock5	clock5 five oclock
1f555	clock6	clock6 oclock six
1f556	clock7	clock7 oclock seven
1f557	clock8	clock8 eight oclock
1f558	clock9	clock9 nine oclock
1f559	clock10	clock10 oclock ten
1f55a	clock11	clock11 eleven oclock
1f55b	clock12	clock12 oclock twelve
1f55c	clock130	clock130 one thirty
1f55d	clock230	clock230 thirty two
1f55e	clock330	clock330 thirty three
1f55f	clock430	clock430 four thirty
1f560	clock530	clock530 five thirty
1f561	clock630	clock630 six thirty
1f562	clock730	clock730 seven thirty
1f563	clock830	clock830 eight thirty
1f564	clock930	clock930 nine thirty
1f565	clock1030	clock1030 ten thirty
1f566	clock1130	clock1130 eleven thirty
1f567	clock1230	clock1230 thirty twelve
1f56f	candle	candle
1f570	mantelpiece_clock	clock mantelpiece
1f573	hole	hole
1f574	business_suit_levitating	business in levitating man person suit
1f575	sleuth_or_spy	detective or sleuth spy
1f576	dark_sunglasses	dark sunglasses
1f577	spider	spider
1f578	spider_web	spider web
1f579	joystick	joystick
1f57a	man_dancing	dancing man
1f587	paperclips	linked paperclips
1f58a	lower_left_ballpoint_pen	ballpoint left lower pen
1f58b	lower_left_fountain_pen	fountain left lower pen
1f58c	lower_left_paintbrush	left lower paintbrush
1f58d	lower_left_crayon	crayon left lower
1f590	raised_hand_with_fingers_splayed	fingers hand raised splayed with
1f595	fu	extended finger fu hand middle reversed with
1f596	raised_hand_with_part_between_middle_and_ring_fingers	and between fingers hand middle part raised ring salute vulcan with
1f5a4	black_heart	black heart
1f5a5	desktop_computer	computer desktop
1f5a8	printer	printer
1f5b1	three_button_mouse	button computer mouse three
1f5b2	trackball	trackball
1f5bc	frame_with_picture	frame framed picture with
1f5c2	card_index_dividers	card dividers index
1f5c3	card_file_box	box card file
1f5c4	file_cabinet	cabinet file
1f5d1	wastebasket	wastebasket
1f5d2	spiral_note_pad	note notepad pad spiral
1f5d3	spiral_calendar_pad	calendar pad spiral
1f5dc	compression	clamp compression
1f5dd	old_key	key old
1f5de	rolled_up_newspaper	newspaper roll rolled up
1f5e1	dagger_knife	dagger knife
1f5e3	speaking_head_in_silhouette	head in silhouette speaking
1f5e8	left_speech_bubble	bubble left speech
1f5ef	right_anger_bubble	anger bubble right
1f5f3	ballot_box	ballot box with
1f5fa	world_map	map world
1f5fb	mount_fuji	fuji mount
1f5fc	tokyo_tower	tokyo tower
1f5fd	statue_of_liberty	liberty of statue
1f5fe	japan	japan map of
1f5ff	moyai	moai moyai
1f600	grinning	face grinning
1f601	grin	beaming eyes face grin smiling with
1f602	joy	face joy of tears with
1f603	smiley	big eyes face grinning smiley with
1f604	smile	eyes face grinning smile smiling with
1f605	sweat_smile	face grinning smile sweat with
1f606	satisfied	face grinning laughing satisfied squinting
1f607	innocent	face halo innocent smiling with
1f608	smiling_imp	face horns imp smiling with
1f609	wink	face wink winking
1f60a	blush	blush eyes face smiling with
1f60b	yum	face food savoring yum
1f60c	relieved	face relieved
1f60d	heart_eyes	eyes face heart smiling with
1f60e	sunglasses	face smiling sunglasses with
1f60f	smirk	face smirk smirking
1f610	neutral_face	face neutral
1f611	expressionless	expressionless face
1f612	unamused	face unamused
1f613	sweat	downcast face sweat with
1f614	pensive	face pensive
1f615	confused	confused face
1f616	confounded	confounded face
1f617	kissing	face kissing
1f618	kissing_heart	a blowing face heart kiss kissing
1f619	kissing_smiling_eyes	eyes face kissing smiling with
1f61a	kissing_closed_eyes	closed eyes face kissing with
1f61b	stuck_out_tongue	face out stuck tongue with
1f61c	stuck_out_tongue_winking_eye	eye face out stuck tongue winking with
1f61d	stuck_out_tongue_closed_eyes	closed eyes face out squinting stuck tongue with
1f61e	disappointed	disappointed face
1f61f	worried	face worried
1f620	angry	angry face
1f621	rage	enraged face pout rage
1f622	cry	cry crying face
1f623	persevere	face persevere persevering
1f624	triumph	face from nose steam triumph with
1f625	disappointed_relieved	but disappointed face relieved sad
1f626	frowning	face frowning mouth open with
1f627	anguished	anguished face
1f628	fearful	face fearful
1f629	weary	face weary
1f62a	sleepy	face sleepy
1f62b	tired_face	face tired
1f62c	grimacing	face grimacing
1f62d	sob	crying face loudly sob
1f62e	open_mouth	face mouth open with
1f62f	hushed	face hushed
1f630	cold_sweat	anxious cold face sweat with
1f631	scream	face fear in scream screaming
1f632	astonished	astonished face
1f633	flushed	face flushed
1f634	sleeping	face sleeping
1f635	dizzy_face	crossed dizzy eyes face knocked out with
1f636	no_mouth	face mouth no without
1f637	mask	face mask medical with
1f638	smile_cat	cat eyes grinning smile smiling with
1f639	joy_cat	cat joy of tears with
1f63a	smiley_cat	cat grinning smiley
1f63b	heart_eyes_cat	cat eyes heart smiling with
1f63c	smirk_cat	cat smile smirk with wry
1f63d	kissing_cat	cat kissing
1f63e	pouting_cat	cat pouting
1f63f	crying_cat_face	cat crying face
1f640	scream_cat	cat scream weary
1f641	slightly_frowning_face	face frowning slightly
1f642	slightly_smiling_face	face slightly smiling
1f643	upside_down_face	down face upside
1f644	roll_eyes	eyes face roll rolling with
1f645	no_good	gesturing good no person
1f646	ok_person	gesturing ok person
1f647	bow	bow bowing person
1f648	see_no_evil	evil monkey no see
1f649	hear_no_evil	evil hear monkey no
1f64a	speak_no_evil	evil monkey no speak
1f64b	raising_hand	hand person raising
1f64c	raised_hands	hands raised raising
1f64d	frowning_person	frowning person
1f64e	pouting_face	face person pouting with
1f64f	pray	folded hands pray
1f680	rocket	rocket
1f681	helicopter	helicopter
1f682	steam_locomotive	locomotive steam
1f683	railway_car	car railway
1f684	bullettrain_side	bullettrain high side speed train
1f685	bullettrain_front	bullet bullettrain front train
1f686	train2	train train2
1f687	metro	metro
1f688	light_rail	light rail
1f689	station	station
1f68a	tram	tram
1f68b	train	car train tram
1f68c	bus	bus
1f68d	oncoming_bus	bus oncoming
1f68e	trolleybus	trolleybus
1f68f	busstop	bus busstop stop
1f690	minibus	minibus
1f691	ambulance	ambulance
1f692	fire_engine	engine fire
1f693	police_car	car police
1f694	oncoming_police_car	car oncoming police
1f695	taxi	taxi
1f696	oncoming_taxi	oncoming taxi
1f697	car	automobile car red
1f698	oncoming_automobile	automobile oncoming
1f699	blue_car	blue car sport utility vehicle
1f69a	truck	delivery truck
1f69b	articulated_lorry	articulated lorry
1f69c	tractor	tractor
1f69d	monorail	monorail
1f69e	mountain_railway	mountain railway
1f69f	suspension_railway	railway suspension
1f6a0	mountain_cableway	cableway mountain
1f6a1	aerial_tramway	aerial tramway
1f6a2	ship	ship
1f6a3	rowboat	boat person rowboat rowing
1f6a4	speedboat	speedboat
1f6a5	traffic_light	horizontal light traffic
1f6a6	vertical_traffic_light	light traffic vertical
1f6a7	construction	construction
1f6a8	rotating_light	car light police rotating
1f6a9	triangular_flag_on_post	flag on post triangular
1f6aa	door	door
1f6ab	no_entry_sign	entry no prohibited sign
1f6ac	smoking	cigarette smoking
1f6ad	no_smoking	no smoking
1f6ae	put_litter_in_its_place	bin in its litter place put sign
1f6af	do_not_litter	do litter littering no not
1f6b0	potable_water	potable water
1f6b1	non_potable_water	non potable water
1f6b2	bike	bicycle bike
1f6b3	no_bicycles	bicycles no
1f6b4	bicyclist	bicyclist biking person
1f6b5	mountain_bicyclist	bicyclist biking mountain person
1f6b6	walking	person walking
1f6b7	no_pedestrians	no pedestrians
1f6b8	children_crossing	children crossing
1f6b9	mens	mens room
1f6ba	womens	room womens
1f6bb	restroom	restroom
1f6bc	baby_symbol	baby symbol
1f6bd	toilet	toilet
1f6be	wc	closet water wc
1f6bf	shower	shower
1f6c0	bath	bath person taking
1f6c1	bathtub	bathtub
1f6c2	passport_control	control passport
1f6c3	customs	customs
1f6c4	baggage_claim	baggage claim
1f6c5	left_luggage	left luggage
1f6cb	couch_and_lamp	and couch lamp
1f6cc	sleeping_bed	accommodation bed in person sleeping
1f6cd	shopping	bags shopping
1f6ce	bellhop_bell	bell bellhop
1f6cf	bed	bed
1f6d0	place_of_worship	of place worship
1f6d1	stop_sign	sign stop
1f6d2	shopping_cart	cart shopping
1f6d5	hindu_temple	hindu temple
1f6d6	hut	hut
1f6d7	elevator	elevator
1f6e0	hammer_and_wrench	and hammer wrench
1f6e1	shield	shield
1f6e2	oil_drum	drum oil
1f6e3	motorway	motorway
1f6e4	railway_track	railway track
1f6e5	motor_boat	boat motor
1f6e9	small_airplane	airplane small
1f6eb	flight_departure	airplane departure flight
1f6ec	airplane_arriving	airplane arrival arriving flight
1f6f0	artificial_satellite	artificial satellite
1f6f3	passenger_ship	passenger ship
1f6f4	kick_scooter	kick scooter
1f6f5	motor_scooter	motor scooter
1f6f6	canoe	canoe
1f6f7	sled	sled
1f6f8	flying_saucer	flying saucer
1f6f9	skateboard	skateboard
1f6fa	auto_rickshaw	auto rickshaw
1f6fb	pickup_truck	pickup truck
1f6fc	roller_skate	roller skate
1f7e0	orange_circle	circle orange
1f7e1	yellow_circle	circle yellow
1f7e2	green_circle	circle green
1f7e3	purple_circle	circle purple
1f7e4	brown_circle	brown circle
1f7e5	red_square	red square
1f7e6	blue_square	blue square
1f7e7	orange_square	orange square
1f7e8	yellow_square	square yellow
1f7e9	green_square	green square
1f7ea	purple_square	purple square
1f7eb	brown_square	brown square
1f90c	pinched_fingers	fingers pinched
1f90d	white_heart	heart white
1f90e	brown_heart	brown heart
1f90f	pinching_hand	hand pinching
1f910	zipper_mouth_face	face mouth zipper
1f911	money_mouth_face	face money mouth
1f912	face_with_thermometer	face thermometer with
1f913	nerd_face	face nerd
1f914	thinking	face thinking
1f915	face_with_head_bandage	bandage face head with
1f916	robot_face	face robot
1f917	hugging_face	face hands hugging hugs open smiling with
1f918	metal	horns metal of sign the
1f919	call_me_hand	call hand me
1f91a	raised_back_of_hand	back hand of raised
1f91b	fist_left	facing fist left
1f91c	fist_right	facing fist right
1f91d	handshake	handshake
1f91e	crossed_fingers	crossed fingers
1f91f	love_you_gesture	gesture love you
1f920	cowboy_hat_face	cowboy face hat
1f921	clown_face	clown face
1f922	nauseated_face	face nauseated
1f923	rofl	floor laughing on rofl rolling the
1f924	drooling_face	drooling face
1f925	lying_face	face lying
1f926	facepalm	facepalm facepalming person
1f927	sneezing_face	face sneezing
1f928	raised_eyebrow	eyebrow face raised with
1f929	star_struck	star struck
1f92a	zany_face	face zany
1f92b	shushing_face	face shushing
1f92c	cursing_face	cursing face mouth on symbols with
1f92d	hand_over_mouth	face hand mouth over with
1f92e	vomiting_face	face vomiting
1f92f	exploding_head	exploding head
1f930	pregnant_woman	pregnant woman
1f931	breast_feeding	breast feeding
1f932	palms_up_together	palms together up
1f933	selfie	selfie
1f934	prince	prince
1f935	person_in_tuxedo	in person tuxedo
1f936	mrs_claus	claus mrs
1f937	shrug	person shrug shrugging
1f938	cartwheeling	cartwheeling person
1f939	juggling_person	juggling person
1f93a	person_fencing	fencing person
1f93c	wrestling	people wrestling
1f93d	water_polo	person playing polo water
1f93e	handball_person	handball person playing
1f93f	diving_mask	diving mask
1f940	wilted_flower	flower wilted
1f941	drum	drum
1f942	clinking_glasses	clinking glasses
1f943	tumbler_glass	glass tumbler
1f944	spoon	spoon
1f945	goal_net	goal net
1f947	1st_place_medal	1st medal place
1f948	2nd_place_medal	2nd medal place
1f949	3rd_place_medal	3rd medal place
1f94a	boxing_glove	boxing glove
1f94b	martial_arts_uniform	arts martial uniform
1f94c	curling_stone	curling stone
1f94d	lacrosse	lacrosse
1f94e	softball	softball
1f94f	flying_disc	disc flying
1f950	croissant	croissant
1f951	avocado	avocado
1f952	cucumber	cucumber
1f953	bacon	bacon
1f954	potato	potato
1f955	carrot	carrot
1f956	baguette_bread	baguette bread
1f957	green_salad	green salad
1f958	shallow_pan_of_food	food of pan shallow
1f959	stuffed_flatbread	flatbread stuffed
1f95a	egg2	egg egg2
1f95b	milk_glass	glass milk of
1f95c	peanuts	peanuts
1f95d	kiwi_fruit	fruit kiwi
1f95e	pancakes	pancakes
1f95f	dumpling	dumpling
1f960	fortune_cookie	cookie fortune
1f961	takeout_box	box takeout
1f962	chopsticks	chopsticks
1f963	bowl_with_spoon	bowl spoon with
1f964	cup_with_straw	cup straw with
1f965	coconut	coconut
1f966	broccoli	broccoli
1f967	pie	pie
1f968	pretzel	pretzel
1f969	cut_of_meat	cut meat of
1f96a	sandwich	sandwich
1f96b	canned_food	canned food
1f96c	leafy_green	green leafy
1f96d	mango	mango
1f96e	moon_cake	cake moon
1f96f	bagel	bagel
1f970	smiling_face_with_three_hearts	face hearts smiling three with
1f971	yawning_face	face yawning
1f972	smiling_face_with_tear	face smiling tear with
1f973	partying_face	face partying
1f974	woozy_face	face woozy
1f975	hot_face	face hot
1f976	cold_face	cold face
1f977	ninja	ninja
1f978	disguised_face	disguised face
1f97a	pleading_face	face pleading
1f97b	sari	sari
1f97c	lab_coat	coat lab
1f97d	goggles	goggles
1f97e	hiking_boot	boot hiking
1f97f	flat_shoe	flat shoe
1f980	crab	crab
1f981	lion_face	face lion
1f982	scorpion	scorpion
1f983	turkey	turkey
1f984	unicorn_face	face unicorn
1f985	eagle	eagle
1f986	duck	duck
1f987	bat	bat
1f988	shark	shark
1f989	owl	owl
1f98a	fox_face	face fox
1f98b	butterfly	butterfly
1f98c	deer	deer
1f98d	harambe	gorilla harambe
1f98e	lizard	lizard
1f98f	rhinoceros	rhinoceros
1f990	shrimp	shrimp
1f991	squid	squid
1f992	giraffe	giraffe
1f993	zebra	zebra
1f994	hedgehog	hedgehog
1f995	sauropod	sauropod
1f996	t_rex	rex t
1f997	cricket	cricket
1f998	kangaroo	kangaroo
1f999	llama	llama
1f99a	peacock	peacock
1f99b	hippopotamus	hippopotamus
1f99c	parrot	parrot
1f99d	raccoon	raccoon
1f99e	lobster	lobster
1f99f	mosquito	mosquito
1f9a0	microbe	microbe
1f9a1	badger	badger
1f9a2	swan	swan
1f9a3	mammoth	mammoth
1f9a4	dodo	dodo
1f9a5	sloth	sloth
1f9a6	otter	otter
1f9a7	orangutan	orangutan
1f9a8	skunk	skunk
1f9a9	flamingo	flamingo
1f9aa	oyster	oyster
1f9ab	beaver	beaver
1f9ac	bison	bison
1f9ad	seal	seal
1f9ae	guide_dog	dog guide
1f9af	probing_cane	cane probing white
1f9b4	bone	bone
1f9b5	leg	leg
1f9b6	foot	foot
1f9b7	tooth	tooth
1f9b8	superhero	superhero
1f9b9	supervillain	supervillain
1f9ba	safety_vest	safety vest
1f9bb	ear_with_hearing_aid	aid ear hearing with
1f9bc	motorized_wheelchair	motorized wheelchair
1f9bd	manual_wheelchair	manual wheelchair
1f9be	mechanical_arm	arm mechanical
1f9bf	mechanical_leg	leg mechanical
1f9c0	cheese	cheese wedge
1f9c1	cupcake	cupcake
1f9c2	salt	salt
1f9c3	beverage_box	beverage box
1f9c4	garlic	garlic
1f9c5	onion	onion
1f9c6	falafel	falafel
1f9c7	waffle	waffle
1f9c8	butter	butter
1f9c9	mate	mate
1f9ca	ice_cube	cube ice
1f9cb	bubble_tea	bubble tea
1f9cd	standing_person	person standing
1f9ce	kneeling_person	kneeling person
1f9cf	deaf_person	deaf person
1f9d0	monocle_face	face monocle with
1f9d1	adult	adult person
1f9d2	child	child
1f9d3	older_adult	adult older person
1f9d4	bearded_person	beard bearded person
1f9d5	woman_with_headscarf	headscarf with woman
1f9d6	sauna_person	in person room sauna steamy
1f9d7	climbing	climbing person
1f9d8	lotus_position	in lotus person position
1f9d9	mage	mage
1f9da	fairy	fairy
1f9db	vampire	vampire
1f9dc	merperson	merperson
1f9dd	elf	elf
1f9de	genie	genie
1f9df	zombie	zombie
1f9e0	brain	brain
1f9e1	orange_heart	heart orange
1f9e2	billed_cap	billed cap
1f9e3	scarf	scarf
1f9e4	gloves	gloves
1f9e5	coat	coat
1f9e6	socks	socks
1f9e7	red_envelope	envelope red
1f9e8	firecracker	firecracker
1f9e9	jigsaw	jigsaw piece puzzle
1f9ea	test_tube	test tube
1f9eb	petri_dish	dish petri
1f9ec	dna	dna
1f9ed	compass	compass
1f9ee	abacus	abacus
1f9ef	fire_extinguisher	extinguisher fire
1f9f0	toolbox	toolbox
1f9f1	bricks	brick bricks
1f9f2	magnet	magnet
1f9f3	luggage	luggage
1f9f4	lotion_bottle	bottle lotion
1f9f5	thread	thread
1f9f6	yarn	yarn
1f9f7	safety_pin	pin safety
1f9f8	teddy_bear	bear teddy
1f9f9	broom	broom
1f9fa	basket	basket
1f9fb	roll_of_paper	of paper roll
1f9fc	soap	soap
1f9fd	sponge	sponge
1f9fe	receipt	receipt
1f9ff	nazar_amulet	amulet nazar
1fa70	ballet_shoes	ballet shoes
1fa71	one_piece_swimsuit	one piece swimsuit
1fa72	swim_brief	brief briefs swim
1fa73	shorts	shorts
1fa74	thong_sandal	sandal thong
1fa78	drop_of_blood	blood drop of
1fa79	adhesive_bandage	adhesive bandage
1fa7a	stethoscope	stethoscope
1fa80	yo_yo	yo
1fa81	kite	kite
1fa82	parachute	parachute
1fa83	boomerang	boomerang
1fa84	magic_wand	magic wand
1fa85	pinata	pinata
1fa86	nesting_dolls	dolls nesting
1fa90	ringed_planet	planet ringed
1fa91	chair	chair
1fa92	razor	razor
1fa93	axe	axe
1fa94	diya_lamp	diya lamp
1fa95	banjo	banjo
1fa96	military_helmet	helmet military
1fa97	accordion	accordion
1fa98	long_drum	drum long
1fa99	coin	coin
1fa9a	carpentry_saw	carpentry saw
1fa9b	screwdriver	screwdriver
1fa9c	ladder	ladder
1fa9d	hook	hook
1fa9e	mirror	mirror
1fa9f	window	window
1faa0	plunger	plunger
1faa1	sewing_needle	needle sewing
1faa2	knot	knot
1faa3	bucket	bucket
1faa4	mouse_trap	mouse trap
1faa5	toothbrush	toothbrush
1faa6	headstone	headstone
1faa7	placard	placard
1faa8	rock	rock
1fab0	fly	fly
1fab1	worm	worm
1fab2	beetle	beetle
1fab3	cockroach	cockroach
1fab4	potted_plant	plant potted
1fab5	wood	wood
1fab6	feather	feather
1fac0	anatomical_heart	anatomical heart
1fac1	lungs	lungs
1fac2	people_hugging	hugging people
1fad0	blueberries	blueberries
1fad1	bell_pepper	bell pepper
1fad2	olive	olive
1fad3	flatbread	flatbread
1fad4	tamale	tamale
1fad5	fondue	fondue
1fad6	teapot	teapot
"""#
}
