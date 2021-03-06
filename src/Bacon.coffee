Bacon = {
  toString: -> "Bacon"
}

Bacon.version = '<version>'

# Bacon has own Error
Exception = (global ? this).Error

# eventTransformer - should return one value or one or many events
Bacon.fromBinder = (binder, eventTransformer = _.id) ->
  new EventStream describe(Bacon, "fromBinder", binder, eventTransformer), (sink) ->
    unbound = false
    unbind = ->
      if unbinder?
        unbinder() unless unbound
        unbound = true
    unbinder = binder (args...) ->
      value = eventTransformer.apply(this, args)
      unless isArray(value) and _.last(value) instanceof Event
        value = [value]

      reply = Bacon.more
      for event in value
        reply = sink(event = toEvent(event))
        if reply == Bacon.noMore or event.isEnd()
          # defer if binder calls handler in sync before returning unbinder
          if unbinder? then unbind() else Bacon.scheduler.setTimeout unbind, 0
          return reply
      reply
    unbind

# eventTransformer - defaults to returning the first argument to handler
Bacon.$ = {}
Bacon.$.asEventStream = (eventName, selector, eventTransformer) ->
  [eventTransformer, selector] = [selector, undefined] if isFunction(selector)
  withDescription(@selector or this, "asEventStream", eventName, Bacon.fromBinder (handler) =>
    @on(eventName, selector, handler)
    => @off(eventName, selector, handler)
  , eventTransformer)

(jQuery ? (Zepto ? undefined))?.fn.asEventStream = Bacon.$.asEventStream

# Wrap DOM EventTarget, Node EventEmitter, or
# [un]bind: (Any, (Any) -> None) -> None interfaces
# common in MVCs as EventStream
#
# target - EventTarget or EventEmitter, source of events
# eventName - event name to bind
# eventTransformer - defaults to returning the first argument to handler
#
# Examples
#
#   Bacon.fromEventTarget(document.body, "click")
#   # => EventStream
#
#   Bacon.fromEventTarget (new EventEmitter(), "data")
#   # => EventStream
#
# Returns EventStream
Bacon.fromEventTarget = (target, eventName, eventTransformer) ->
  sub = target.addEventListener ? (target.addListener ? target.bind)
  unsub = target.removeEventListener ? (target.removeListener ? target.unbind)
  withDescription(Bacon, "fromEventTarget", target, eventName, Bacon.fromBinder (handler) ->
    sub.call(target, eventName, handler)
    -> unsub.call(target, eventName, handler)
  , eventTransformer)

Bacon.fromPromise = (promise, abort) ->
  withDescription(Bacon, "fromPromise", promise, Bacon.fromBinder (handler) ->
    promise.then(handler, (e) -> handler(new Error(e)))
    -> promise.abort?() if abort
  , ((value) -> [value, end()]))

Bacon.noMore = ["<no-more>"]

Bacon.more = ["<more>"]

Bacon.later = (delay, value) ->
  withDescription(Bacon, "later", delay, value, Bacon.fromPoll(delay, -> [value, end()]))

Bacon.sequentially = (delay, values) ->
  index = 0
  withDescription(Bacon, "sequentially", delay, values, Bacon.fromPoll delay, ->
    value = values[index++]
    if index < values.length
      value
    else if index == values.length
      [value, end()]
    else
      end())

Bacon.repeatedly = (delay, values) ->
  index = 0
  withDescription(Bacon, "repeatedly", delay, values, Bacon.fromPoll(delay, -> values[index++ % values.length]))

Bacon.spy = (spy) -> spys.push(spy)

spys = []
registerObs = (obs) ->
  if spys.length
    unless registerObs.running
      try
        registerObs.running = true
        for spy in spys
          spy(obs)
      finally
        delete registerObs.running
  undefined

withMethodCallSupport = (wrapped) ->
  (f, args...) ->
    if typeof f == "object" and args.length
      context = f
      methodName = args[0]
      f = ->
        context[methodName](arguments...)
      args = args.slice(1)
    wrapped(f, args...)

liftCallback = (desc, wrapped) ->
  withMethodCallSupport (f, args...) ->
    stream = partiallyApplied(wrapped, [(values, callback) ->
      f(values..., callback)])
    withDescription(Bacon, desc, f, args..., Bacon.combineAsArray(args).flatMap(stream))

Bacon.fromCallback = liftCallback "fromCallback", (f, args...) ->
  Bacon.fromBinder (handler) ->
    makeFunction(f, args)(handler)
    nop
  , ((value) -> [value, end()])

Bacon.fromNodeCallback = liftCallback "fromNodeCallback", (f, args...) ->
  Bacon.fromBinder (handler) ->
    makeFunction(f, args)(handler)
    nop
  , (error, value) ->
    return [new Error(error), end()] if error
    [value, end()]

Bacon.fromPoll = (delay, poll) ->
  withDescription(Bacon, "fromPoll", delay, poll,
  (Bacon.fromBinder(((handler) ->
    id = Bacon.scheduler.setInterval(handler, delay)
    -> Bacon.scheduler.clearInterval(id)), poll)))

Bacon.interval = (delay, value) ->
  value = {} unless value?
  withDescription(Bacon, "interval", delay, value, Bacon.fromPoll(delay, -> next(value)))

Bacon.constant = (value) ->
  new Property describe(Bacon, "constant", value), (sink) ->
    sink (initial value)
    sink (end())
    nop

Bacon.never = ->
  new EventStream describe(Bacon, "never"), (sink) ->
    sink (end())
    nop

Bacon.once = (value) ->
  new EventStream describe(Bacon, "once", value), (sink) ->
    sink (toEvent(value))
    sink (end())
    nop


Bacon.fromArray = (values) ->
  assertArray values
  i = 0
  new EventStream describe(Bacon, "fromArray", values), (sink) ->
    unsubd = false
    reply = Bacon.more
    while (reply != Bacon.noMore) and !unsubd
      if i >= values.length
        sink(end())
        reply = Bacon.noMore
      else
        value = values[i++]
        reply = sink(toEvent(value))
    -> unsubd = true

Bacon.mergeAll = (streams...) ->
  if isArray streams[0]
    streams = streams[0]
  if streams.length
    new EventStream describe(Bacon, "mergeAll", streams...), (sink) ->
      ends = 0
      smartSink = (obs) -> (unsubBoth) -> obs.dispatcher.subscribe (event) ->
        if event.isEnd()
          ends++
          if ends == streams.length
            sink end()
          else
            Bacon.more
        else
          reply = sink event
          unsubBoth() if reply == Bacon.noMore
          reply
      sinks = _.map smartSink, streams
      compositeUnsubscribe sinks...
  else
    Bacon.never()

Bacon.zipAsArray = (streams...) ->
  if isArray streams[0]
    streams = streams[0]
  withDescription(Bacon, "zipAsArray", streams..., Bacon.zipWith(streams, (xs...) -> xs))

Bacon.zipWith = (f, streams...) ->
  unless isFunction(f)
    [streams, f] = [f, streams[0]]
  streams = _.map(((s) -> s.toEventStream()), streams)
  withDescription(Bacon, "zipWith", f, streams..., Bacon.when(streams, f))

Bacon.groupSimultaneous = (streams...) ->
  if (streams.length == 1 and isArray(streams[0]))
    streams = streams[0]
  sources = for s in streams
    new BufferingSource(s)
  withDescription(Bacon, "groupSimultaneous", streams..., Bacon.when(sources, ((xs...) -> xs)))

Bacon.combineAsArray = (streams...) ->
  if (streams.length == 1 and isArray(streams[0]))
    streams = streams[0]
  for stream, index in streams
    streams[index] = Bacon.constant(stream) unless (isObservable(stream))
  if streams.length
    sources = for s in streams
      new Source(s, true)
    withDescription(Bacon, "combineAsArray", streams..., Bacon.when(sources, ((xs...) -> xs)).toProperty())
  else
    Bacon.constant([])

Bacon.onValues = (streams..., f) -> Bacon.combineAsArray(streams).onValues(f)

Bacon.combineWith = (f, streams...) ->
  withDescription(Bacon, "combineWith", f, streams..., Bacon.combineAsArray(streams).map (values) -> f(values...))

Bacon.combineTemplate = (template) ->
  funcs = []
  streams = []
  current = (ctxStack) -> ctxStack[ctxStack.length - 1]
  setValue = (ctxStack, key, value) -> current(ctxStack)[key] = value
  applyStreamValue = (key, index) -> (ctxStack, values) -> setValue(ctxStack, key, values[index])
  constantValue = (key, value) -> (ctxStack) -> setValue(ctxStack, key, value)
  mkContext = (template) -> if isArray(template) then [] else {}
  compile = (key, value) ->
    if (isObservable(value))
      streams.push(value)
      funcs.push(applyStreamValue(key, streams.length - 1))
    else if (value == Object(value) and typeof value != "function" and !(value instanceof RegExp) and !(value instanceof Date))
      pushContext = (key) -> (ctxStack) ->
        newContext = mkContext(value)
        setValue(ctxStack, key, newContext)
        ctxStack.push(newContext)
      popContext = (ctxStack) -> ctxStack.pop()
      funcs.push(pushContext(key))
      compileTemplate(value)
      funcs.push(popContext)
    else
      funcs.push(constantValue(key, value))
  compileTemplate = (template) -> _.each(template, compile)
  compileTemplate template
  combinator = (values) ->
    rootContext = mkContext(template)
    ctxStack = [rootContext]
    for f in funcs
      f(ctxStack, values)
    rootContext
  withDescription(Bacon, "combineTemplate", template, Bacon.combineAsArray(streams).map(combinator))

Bacon.retry = (options) ->
  throw new Exception("'source' option has to be a function") unless isFunction(options.source)
  source = options.source
  retries = options.retries or 0
  maxRetries = options.maxRetries or retries
  delay = options.delay or -> 0
  isRetryable = options.isRetryable or -> true

  retry = (context) ->
    nextAttemptOptions = {source, retries: retries - 1, maxRetries, delay, isRetryable}
    delayedRetry = -> Bacon.retry(nextAttemptOptions)
    Bacon.later(delay(context)).filter(false).concat(Bacon.once().flatMap(delayedRetry))

  withDescription(Bacon, "retry", options, source().flatMapError (e) ->
    if isRetryable(e) and retries > 0
      retry({error: e, retriesDone: maxRetries - retries})
    else
      Bacon.once(new Error(e)))

eventIdCounter = 0

class Event
  constructor: ->
    @id = (++eventIdCounter)
  isEvent: -> true
  isEnd: -> false
  isInitial: -> false
  isNext: -> false
  isError: -> false
  hasValue: -> false
  filter: -> true
  inspect: -> @toString()
  log: -> @toString()

class Next extends Event
  constructor: (valueF) ->
    super()
    if isFunction(valueF)
      @value = _.cached(valueF)
    else
      @value = _.always(valueF)
  isNext: -> true
  hasValue: -> true
  fmap: (f) ->
    value = @value
    @apply(-> f(value()))
  apply: (value) -> new Next(value)
  filter: (f) -> f(@value())
  toString: -> _.toString(@value())
  log: -> @value()

class Initial extends Next
  isInitial: -> true
  isNext: -> false
  apply: (value) -> new Initial(value)
  toNext: -> new Next(@value)

class End extends Event
  isEnd: -> true
  fmap: -> this
  apply: -> this
  toString: -> "<end>"

class Error extends Event
  constructor: (@error) ->
  isError: -> true
  fmap: -> this
  apply: -> this
  toString: ->
    "<error> " + _.toString(@error)

idCounter = 0

class Observable
  constructor: (desc) ->
    @id = ++idCounter
    withDescription(desc, this)
    @initialDesc = @desc
  
  subscribe: (sink) ->
    UpdateBarrier.wrappedSubscribe(this, sink)

  onValue: ->
    f = makeFunctionArgs(arguments)
    @subscribe (event) ->
      f event.value() if event.hasValue()

  onValues: (f) ->
    @onValue (args) -> f(args...)

  onError: ->
    f = makeFunctionArgs(arguments)
    @subscribe (event) ->
      f event.error if event.isError()

  onEnd: ->
    f = makeFunctionArgs(arguments)
    @subscribe (event) ->
      f() if event.isEnd()

  errors: -> withDescription(this, "errors", @filter(-> false))

  filter: (f, args...) ->
    convertArgsToFunction this, f, args, (f) ->
      withDescription(this, "filter", f, @withHandler (event) ->
        if event.filter(f)
          @push event
        else
          Bacon.more)

  takeWhile: (f, args...) ->
    convertArgsToFunction this, f, args, (f) ->
      withDescription(this, "takeWhile", f, @withHandler (event) ->
        if event.filter(f)
          @push event
        else
          @push end()
          Bacon.noMore)

  endOnError: (f, args...) ->
    f = true unless f?
    convertArgsToFunction this, f, args, (f) ->
      withDescription(this, "endOnError", @withHandler (event) ->
        if event.isError() and f(event.error)
          @push event
          @push end()
        else
          @push event)

  take: (count) ->
    return Bacon.never() if count <= 0
    withDescription(this, "take", count, @withHandler (event) ->
      unless event.hasValue()
        @push event
      else
        count--
        if count > 0
          @push event
        else
          @push event if count == 0
          @push end()
          Bacon.noMore)

  map: (p, args...) ->
    if (p instanceof Property)
      p.sampledBy(this, former)
    else
      convertArgsToFunction this, p, args, (f) ->
        withDescription(this, "map", f, @withHandler (event) ->
          @push event.fmap(f))

  mapError: ->
    f = makeFunctionArgs(arguments)
    withDescription(this, "mapError", f, @withHandler (event) ->
      if event.isError()
        @push next (f event.error)
      else
        @push event)

  mapEnd: ->
    f = makeFunctionArgs(arguments)
    withDescription(this, "mapEnd", f, @withHandler (event) ->
      if (event.isEnd())
        @push next(f(event))
        @push end()
        Bacon.noMore
      else
        @push event)

  doAction: ->
    f = makeFunctionArgs(arguments)
    withDescription(this, "doAction", f, @withHandler (event) ->
      f(event.value()) if event.hasValue()
      @push event)

  skip: (count) ->
    withDescription(this, "skip", count, @withHandler (event) ->
      unless event.hasValue()
        @push event
      else if (count > 0)
        count--
        Bacon.more
      else
        @push event)

  skipDuplicates: (isEqual = (a, b) -> a == b) ->
    withDescription(this, "skipDuplicates",
      @withStateMachine None, (prev, event) ->
        unless event.hasValue()
          [prev, [event]]
        else if event.isInitial() or prev == None or !isEqual(prev.get(), event.value())
          [new Some(event.value()), [event]]
        else
          [prev, []])

  skipErrors: ->
    withDescription(this, "skipErrors", @withHandler (event) ->
      if event.isError()
        Bacon.more
      else
        @push event)

  withStateMachine: (initState, f) ->
    state = initState
    withDescription(this, "withStateMachine", initState, f, @withHandler (event) ->
      fromF = f(state, event)
      [newState, outputs] = fromF
      state = newState
      reply = Bacon.more
      for output in outputs
        reply = @push output
        if reply == Bacon.noMore
          return reply
      reply)

  scan: (seed, f, options = {}) ->
    f_ = toCombinator(f)
    f = if options.lazyF then f_ else (x,y) -> f_(x(), y())
    acc = toOption(seed).map((x) -> _.always(x))
    subscribe = (sink) =>
      initSent = false
      unsub = nop
      reply = Bacon.more
      sendInit = ->
        unless initSent
          acc.forEach (valueF) ->
            initSent = true
            reply = sink(new Initial(valueF))
            if (reply == Bacon.noMore)
              unsub()
              unsub = nop
      unsub = @dispatcher.subscribe (event) ->
        if (event.hasValue())
          if (initSent and event.isInitial())
            Bacon.more # init already sent, skip this one
          else
            sendInit() unless event.isInitial()
            initSent = true
            prev = acc.getOrElse(-> undefined)
            next = _.cached(-> f(prev, event.value))
            acc = new Some(next)
            next() if (options.eager)
            sink (event.apply(next))
        else
          if event.isEnd()
            reply = sendInit()
          sink event unless reply == Bacon.noMore
      UpdateBarrier.whenDoneWith resultProperty, sendInit
      unsub
    resultProperty = new Property describe(this, "scan", seed, f), subscribe

  fold: (seed, f, options) ->
    withDescription(this, "fold", seed, f, @scan(seed, f, options).sampledBy(@filter(false).mapEnd().toProperty()))

  zip: (other, f = Array) ->
    withDescription(this, "zip", other,
      Bacon.zipWith([this,other], f))

  diff: (start, f) ->
    f = toCombinator(f)
    withDescription(this, "diff", start, f,
      @scan([start], (prevTuple, next) ->
        [next, f(prevTuple[0], next)])
      .filter((tuple) -> tuple.length == 2)
      .map((tuple) -> tuple[1]))

  flatMap: ->
    flatMap_ this, makeSpawner(arguments)

  flatMapFirst: ->
    flatMap_ this, makeSpawner(arguments), true

  flatMapWithConcurrencyLimit: (limit, args...) ->
    withDescription(this, "flatMapWithConcurrencyLimit", limit, args...,
      flatMap_ this, makeSpawner(args), false, limit)

  flatMapLatest: ->
    f = makeSpawner(arguments)
    stream = @toEventStream()
    withDescription(this, "flatMapLatest", f, stream.flatMap (value) ->
      makeObservable(f(value)).takeUntil(stream))

  flatMapError: (fn) =>
    withDescription(this, "flatMapError", fn, @mapError((err) -> new Error(err)).flatMap (x) ->
      if x instanceof Error
        fn(x.error)
      else
        Bacon.once(x))

  flatMapConcat: ->
    withDescription(this, "flatMapConcat", arguments...,
      @flatMapWithConcurrencyLimit 1, arguments...)

  bufferingThrottle: (minimumInterval) ->
    withDescription(this, "bufferingThrottle", minimumInterval,
      @flatMapConcat (x) ->
        Bacon.once(x).concat(Bacon.later(minimumInterval).filter(false)))

  not: -> withDescription(this, "not", @map((x) -> !x))
  
  log: (args...) ->
    @subscribe (event) -> console?.log?(args..., event.log())
    this

  slidingWindow: (n, minValues = 0) ->
    withDescription(this, "slidingWindow", n, minValues, @scan([], ((window, value) -> window.concat([value]).slice(-n)))
          .filter(((values) -> values.length >= minValues)))

  combine: (other, f) ->
    combinator = toCombinator(f)
    withDescription(this, "combine", other, f,
      Bacon.combineAsArray(this, other)
        .map (values) ->
          combinator(values[0], values[1]))

  decode: (cases) -> withDescription(this, "decode", cases, @combine(Bacon.combineTemplate(cases), (key, values) -> values[key]))

  awaiting: (other) ->
    withDescription(this, "awaiting", other,
      Bacon.groupSimultaneous(this, other)
        .map(([myValues, otherValues]) -> otherValues.length == 0)
        .toProperty(false).skipDuplicates())

  name: (name) ->
    @_name = name
    this

  withDescription: ->
    describe(arguments...).apply(this)

  toString: ->
    if @_name
      @_name
    else
      @desc.toString()

  internalDeps: ->
    @initialDesc.deps()

Observable :: reduce = Observable :: fold
Observable :: assign = Observable :: onValue
Observable :: inspect = Observable :: toString

flatMap_ = (root, f, firstOnly, limit) ->
  rootDep = [root]
  childDeps = []
  result = new EventStream describe(root, "flatMap" + (if firstOnly then "First" else ""), f), (sink) ->
    composite = new CompositeUnsubscribe()
    queue = []
    spawn = (event) ->
      child = makeObservable(f event.value())
      childDeps.push(child)
      composite.add (unsubAll, unsubMe) -> child.dispatcher.subscribe (event) ->
        if event.isEnd()
          _.remove(child, childDeps)
          checkQueue()
          checkEnd(unsubMe)
          Bacon.noMore
        else
          if event instanceof Initial
            # To support Property as the spawned stream
            event = event.toNext()
          reply = sink event
          unsubAll() if reply == Bacon.noMore
          reply
    checkQueue = ->
      event = queue.shift()
      spawn event if event
    checkEnd = (unsub) ->
      unsub()
      sink end() if composite.empty()
    composite.add (__, unsubRoot) -> root.dispatcher.subscribe (event) ->
      if event.isEnd()
        checkEnd(unsubRoot)
      else if event.isError()
        sink event
      else if firstOnly and composite.count() > 1
        Bacon.more
      else
        return Bacon.noMore if composite.unsubscribed
        if limit and composite.count() > limit
          queue.push(event)
        else
          spawn event
    composite.unsubscribe
  result.internalDeps = -> if (childDeps.length) then rootDep.concat(childDeps) else rootDep
  result

class EventStream extends Observable
  constructor: (desc, subscribe) ->
    if isFunction(desc)
      subscribe = desc
      desc = []
    super(desc)
    assertFunction subscribe
    @dispatcher = new Dispatcher(subscribe)
    registerObs(this)

  delay: (delay) ->
    withDescription(this, "delay", delay, @flatMap (value) ->
      Bacon.later delay, value)

  debounce: (delay) ->
    withDescription(this, "debounce", delay, @flatMapLatest (value) ->
      Bacon.later delay, value)

  debounceImmediate: (delay) ->
    withDescription(this, "debounceImmediate", delay, @flatMapFirst (value) ->
      Bacon.once(value).concat(Bacon.later(delay).filter(false)))

  throttle: (delay) ->
    withDescription(this, "throttle", delay, @bufferWithTime(delay).map((values) -> values[values.length - 1]))

  bufferWithTime: (delay) ->
    withDescription(this, "bufferWithTime", delay, @bufferWithTimeOrCount(delay, Number.MAX_VALUE))

  bufferWithCount: (count) ->
    withDescription(this, "bufferWithCount", count, @bufferWithTimeOrCount(undefined, count))

  bufferWithTimeOrCount: (delay, count) ->
    flushOrSchedule = (buffer) ->
      if buffer.values.length == count
        buffer.flush()
      else if (delay != undefined)
        buffer.schedule()
    withDescription(this, "bufferWithTimeOrCount", delay, count, @buffer(delay, flushOrSchedule, flushOrSchedule))

  buffer: (delay, onInput = nop, onFlush = nop) ->
    buffer = {
      scheduled: false
      end: undefined
      values: []
      flush: ->
        @scheduled = false
        if @values.length > 0
          reply = @push next(@values)
          @values = []
          if @end?
            @push @end
          else if reply != Bacon.noMore
            onFlush(this)
        else
          @push @end if @end?
      schedule: ->
        unless @scheduled
          @scheduled = true
          delay(=> @flush())
    }
    reply = Bacon.more
    unless isFunction(delay)
      delayMs = delay
      delay = (f) -> Bacon.scheduler.setTimeout(f, delayMs)
    withDescription(this, "buffer", @withHandler (event) ->
      buffer.push = (event) => @push(event)
      if event.isError()
        reply = @push event
      else if event.isEnd()
        buffer.end = event
        unless buffer.scheduled
          buffer.flush()
      else
        buffer.values.push(event.value())
        onInput(buffer)
      reply)

  merge: (right) ->
    assertEventStream(right)
    left = this
    withDescription(left, "merge", right, Bacon.mergeAll(this, right))

  toProperty: (initValue) ->
    initValue = None if arguments.length == 0
    withDescription(this, "toProperty", initValue, @scan(initValue, latterF, {lazyF: true}))

  toEventStream: -> this

  sampledBy: (sampler, combinator) ->
    withDescription(this, "sampledBy", sampler, combinator,
      @toProperty().sampledBy(sampler, combinator))

  concat: (right) ->
    left = this
    new EventStream describe(left, "concat", right), (sink) ->
      unsubRight = nop
      unsubLeft = left.dispatcher.subscribe (e) ->
        if e.isEnd()
          unsubRight = right.dispatcher.subscribe sink
        else
          sink(e)
      -> unsubLeft() ; unsubRight()

  takeUntil: (stopper) ->
    endMarker = {}
    withDescription(this, "takeUntil", stopper, Bacon.groupSimultaneous(@mapEnd(endMarker), stopper.skipErrors())
      .withHandler((event) ->
        unless event.hasValue()
          @push event
        else
          [data, stopper] = event.value()
          if stopper.length
            @push end()
          else
            reply = Bacon.more
            for value in data
              if value == endMarker
                reply = @push end()
              else
                reply = @push next(value)
            reply
      ))

  skipUntil: (starter) ->
    started = starter.take(1).map(true).toProperty(false)
    withDescription(this, "skipUntil", starter, @filter(started))

  skipWhile: (f, args...) ->
    ok = false
    convertArgsToFunction this, f, args, (f) ->
      withDescription(this, "skipWhile", f, @withHandler (event) ->
        if ok or !event.hasValue() or !f(event.value())
          ok = true if event.hasValue()
          @push event
        else
          Bacon.more)

  holdWhen: (valve) ->
    valve_ = valve.startWith(false)
    releaseHold = valve_.filter (x) -> !x
    putToHold = valve_.filter _.id

    withDescription(this, "holdWhen", valve,
      # the filter(false) thing is added just to keep the subscription active all the time (improves stability with some streams)
      @filter(false).merge valve_.flatMapConcat (shouldHold) =>
        unless shouldHold
          @takeUntil(putToHold)
        else
          @scan([], ((xs,x) -> xs.concat(x)), {eager: true}).sampledBy(releaseHold).take(1).flatMap(Bacon.fromArray))

  startWith: (seed) ->
    withDescription(this, "startWith", seed,
      Bacon.once(seed).concat(this))

  withHandler: (handler) ->
    dispatcher = new Dispatcher(@dispatcher.subscribe, handler)
    new EventStream describe(this, "withHandler", handler), dispatcher.subscribe

class Property extends Observable
  constructor: (desc, subscribe, handler) ->
    if isFunction(desc)
      handler = subscribe
      subscribe = desc
      desc = []
    super(desc)
    assertFunction(subscribe)
    @dispatcher = new PropertyDispatcher(this, subscribe, handler)
    registerObs(this)

  sampledBy: (sampler, combinator) ->
    if combinator?
      combinator = toCombinator combinator
    else
      lazy = true
      combinator = (f) -> f()
    thisSource = new Source(this, false, lazy)
    samplerSource = new Source(sampler, true, lazy)
    stream = Bacon.when([thisSource, samplerSource], combinator)
    result = if sampler instanceof Property then stream.toProperty() else stream
    withDescription(this, "sampledBy", sampler, combinator, result)

  sample: (interval) ->
    withDescription(this, "sample", interval,
      @sampledBy Bacon.interval(interval, {}))

  changes: -> new EventStream describe(this, "changes"), (sink) =>
    @dispatcher.subscribe (event) ->
      #console.log "CHANGES", event.toString()
      sink event unless event.isInitial()

  withHandler: (handler) ->
    new Property describe(this, "withHandler", handler), @dispatcher.subscribe, handler

  toProperty: ->
    assertNoArguments(arguments)
    this

  toEventStream: ->
    new EventStream describe(this, "toEventStream"), (sink) =>
      @dispatcher.subscribe (event) ->
        event = event.toNext() if event.isInitial()
        sink event

  and: (other) -> withDescription(this, "and", other, @combine(other, (x, y) -> x and y))

  or: (other) -> withDescription(this, "or", other, @combine(other, (x, y) -> x or y))

  delay: (delay) -> @delayChanges("delay", delay, (changes) -> changes.delay(delay))

  debounce: (delay) -> @delayChanges("debounce", delay, (changes) -> changes.debounce(delay))

  throttle: (delay) -> @delayChanges("throttle", delay, (changes) -> changes.throttle(delay))

  delayChanges: (desc..., f) ->
    withDescription(this, desc...,
      addPropertyInitValueToStream(this, f(@changes())))

  takeUntil: (stopper) ->
    changes = @changes().takeUntil(stopper)
    withDescription(this, "takeUntil", stopper,
      addPropertyInitValueToStream(this, changes))

  startWith: (value) ->
    withDescription(this, "startWith", value,
      @scan(value, (prev, next) -> next))
  
  bufferingThrottle: ->
    super.bufferingThrottle(arguments...).toProperty()

convertArgsToFunction = (obs, f, args, method) ->
  if f instanceof Property
    sampled = f.sampledBy(obs, (p,s) -> [p,s])
    method.call(sampled, ([p, s]) -> p)
      .map(([p, s]) -> s)
  else
    f = makeFunction(f, args)
    method.call(obs, f)

addPropertyInitValueToStream = (property, stream) ->
  justInitValue = new EventStream describe(property, "justInitValue"), (sink) ->
    value = undefined
    unsub = property.dispatcher.subscribe (event) ->
      if !event.isEnd()
        value = event
      Bacon.noMore
    UpdateBarrier.whenDoneWith justInitValue, ->
      if value?
        sink value
      sink end()
    unsub
  justInitValue.concat(stream).toProperty()

class Dispatcher
  constructor: (@_subscribe, @_handleEvent) ->
    @subscriptions = []
    @queue = []
    @pushing = false
    @ended = false
    @prevError = undefined
    @unsubscribeFromSource = nop

  hasSubscribers: ->
    @subscriptions.length > 0

  removeSub: (subscription) =>
    @subscriptions = _.without(subscription, @subscriptions)

  push: (event) ->
    UpdateBarrier.inTransaction event, this, @pushIt, [event]

  pushIt: (event) ->
    unless @pushing
      return if event == @prevError
      @prevError = event if event.isError()
      success = false
      try
        @pushing = true
        tmp = @subscriptions
        for sub in tmp
          reply = sub.sink event
          @removeSub sub if reply == Bacon.noMore or event.isEnd()
        success = true
      finally
        @pushing = false
        @queue = [] unless success # ditch queue in case of exception to avoid unexpected behavior
      success = true
      while @queue.length
        event = @queue.shift()
        @push event
      if @hasSubscribers()
        Bacon.more
      else
        @unsubscribeFromSource()
        Bacon.noMore
    else
      @queue.push(event)
      Bacon.more

  handleEvent: (event) =>
    if event.isEnd()
      @ended = true

    if @_handleEvent
      @_handleEvent(event)
    else
      @push event

  subscribe: (sink) =>
    if @ended
      sink end()
      nop
    else
      assertFunction sink
      subscription = { sink: sink }
      @subscriptions.push(subscription)
      if @subscriptions.length == 1
        unsubSrc = @_subscribe @handleEvent
        @unsubscribeFromSource = ->
          unsubSrc()
          @unsubscribeFromSource = nop
      assertFunction @unsubscribeFromSource
      =>
        @removeSub subscription
        @unsubscribeFromSource() unless @hasSubscribers()

class PropertyDispatcher extends Dispatcher
  constructor: (@property, subscribe, handleEvent) ->
    super(subscribe, handleEvent)
    @current = None
    @currentValueRootId = undefined
    @propertyEnded = false

  push: (event) ->
    if event.isEnd()
      @propertyEnded = true
    if event.hasValue()
      @current = new Some(event)
      @currentValueRootId = UpdateBarrier.currentEventId()
    super(event)

  maybeSubSource: (sink, reply) ->
    if reply == Bacon.noMore
      nop
    else if @propertyEnded
      sink end()
      nop
    else
      Dispatcher::subscribe.call(this, sink)

  subscribe: (sink) =>
    initSent = false
    # init value is "bounced" here because the base Dispatcher class
    # won't add more than one subscription to the underlying observable.
    # without bouncing, the init value would be missing from all new subscribers
    # after the first one
    reply = Bacon.more

    if @current.isDefined and (@hasSubscribers() or @propertyEnded)
      # should bounce init value
      dispatchingId = UpdateBarrier.currentEventId()
      valId = @currentValueRootId
      if !@propertyEnded and valId and dispatchingId and dispatchingId != valId
        # when subscribing while already dispatching a value and this property hasn't been updated yet
        # we cannot bounce before this property is up to date.
        #console.log "bouncing with possibly stale value", event.value(), "root at", valId, "vs", dispatchingId
        UpdateBarrier.whenDoneWith @property, =>
          if @currentValueRootId == valId
            sink initial(@current.get().value())
        # the subscribing thing should be defered
        @maybeSubSource(sink, reply)
      else
        #console.log "bouncing value immediately"
        UpdateBarrier.inTransaction(undefined, this, (->
          reply = try
            sink initial(@current.get().value())
          catch
            Bacon.more
        ), [])
        @maybeSubSource(sink, reply)
    else
      @maybeSubSource(sink, reply)

class Bus extends EventStream
  constructor: ->
    @sink = undefined
    @subscriptions = []
    @ended = false
    super(describe(Bacon, "Bus"), @subscribeAll)

  unsubAll: =>
    sub.unsub?() for sub in @subscriptions
    undefined

  subscribeAll: (newSink) =>
    @sink = newSink
    for subscription in cloneArray(@subscriptions)
      @subscribeInput(subscription)
    @unsubAll

  guardedSink: (input) => (event) =>
    if (event.isEnd())
      @unsubscribeInput(input)
      Bacon.noMore
    else
      @sink event

  subscribeInput: (subscription) ->
    subscription.unsub = (subscription.input.dispatcher.subscribe(@guardedSink(subscription.input)))

  unsubscribeInput: (input) ->
    for sub, i in @subscriptions
      if sub.input == input
        sub.unsub?()
        @subscriptions.splice(i, 1)
        return

  plug: (input) ->
    return if @ended
    sub = { input: input }
    @subscriptions.push(sub)
    @subscribeInput(sub) if (@sink?)
    => @unsubscribeInput(input)

  end: ->
    @ended = true
    @unsubAll()
    @sink? end()

  push: (value) ->
    @sink? next(value)

  error: (error) ->
    @sink? new Error(error)

class Source
  constructor: (@obs, @sync, @lazy = false) ->
    @queue = []
  subscribe: (sink) -> @obs.dispatcher.subscribe(sink)
  toString: -> @obs.toString.call(this)
  markEnded: -> @ended = true
  consume: ->
    if @lazy
      _.always(@queue[0])
    else
      @queue[0]
  push: (x) -> @queue = [x]
  mayHave: -> true
  hasAtLeast: -> @queue.length
  flatten: true

class ConsumingSource extends Source
  consume: -> @queue.shift()
  push: (x) -> @queue.push(x)
  mayHave: (c) -> !@ended or @queue.length >= c
  hasAtLeast: (c) -> @queue.length >= c
  flatten: false

class BufferingSource extends Source
  constructor: (obs) ->
    super(obs, true)
  consume: ->
    values = @queue
    @queue = []
    -> values
  push: (x) -> @queue.push(x())
  hasAtLeast: -> true

Source.isTrigger = (s) ->
  if s instanceof Source
    s.sync
  else
    s instanceof EventStream

Source.fromObservable = (s) ->
  if s instanceof Source
    s
  else if s instanceof Property
    new Source(s, false)
  else
    new ConsumingSource(s, true)

describe = (context, method, args...) ->
  if (context or method) instanceof Desc
    context or method
  else
    new Desc(context, method, args)

findDeps = (x) ->
  if isArray(x)
    _.flatMap findDeps, x
  else if isObservable(x)
    [x]
  else if x instanceof Source
    [x.obs]
  else
    []

class Desc
  constructor: (@context, @method, @args) ->
    @cached = undefined
  deps: ->
    @cached or= findDeps([@context].concat(@args))
  apply: (obs) ->
    obs.desc = this
    obs
  toString: ->
    _.toString(@context) + "." + _.toString(@method) + "(" + _.map(_.toString, @args) + ")"

withDescription = (desc..., obs) ->
  describe(desc...).apply(obs)

Bacon.when = ->
  return Bacon.never() if arguments.length == 0
  len = arguments.length
  usage = "when: expecting arguments in the form (Observable+,function)+"

  assert usage, (len % 2 == 0)
  sources = []
  pats = []
  i = 0
  patterns = []
  while (i < len)
    patterns[i] = arguments[i]
    patterns[i + 1] = arguments[i + 1]
    patSources = _.toArray arguments[i]
    f = arguments[i + 1]
    pat = {f: (if isFunction(f) then f else (-> f)), ixs: []}
    triggerFound = false
    for s in patSources
      index = _.indexOf(sources, s)
      unless triggerFound
        triggerFound = Source.isTrigger(s)
      if index < 0
        sources.push(s)
        index = sources.length - 1
      (ix.count++ if ix.index == index) for ix in pat.ixs
      pat.ixs.push {index: index, count: 1}
    assert "At least one EventStream required", (triggerFound or (!patSources.length))

    pats.push pat if patSources.length > 0
    i = i + 2

  unless sources.length
    return Bacon.never()

  sources = _.map Source.fromObservable, sources
  needsBarrier = (_.any sources, (s) -> s.flatten) and (containsDuplicateDeps (_.map ((s) -> s.obs), sources))

  resultStream = new EventStream describe(Bacon, "when", patterns...), (sink) ->
    triggers = []
    ends = false
    match = (p) ->
      for i in p.ixs
        unless sources[i.index].hasAtLeast(i.count)
          return false
      return true
    cannotSync = (source) ->
      !source.sync or source.ended
    cannotMatch = (p) ->
      for i in p.ixs
        unless sources[i.index].mayHave(i.count)
          return true
    nonFlattened = (trigger) -> !trigger.source.flatten
    part = (source) -> (unsubAll) ->
      flushLater = ->
        UpdateBarrier.whenDoneWith resultStream, flush
      flushWhileTriggers = ->
        if triggers.length > 0
          reply = Bacon.more
          trigger = triggers.pop()
          for p in pats
            if match(p)
              #console.log "match", p
              functions = (sources[i.index].consume() for i in p.ixs)
              reply = sink trigger.e.apply ->
                values = (fun() for fun in functions)
                p.f(values...)
              if triggers.length
                triggers = _.filter nonFlattened, triggers
              if reply == Bacon.noMore
                return reply
              else
                return flushWhileTriggers()
        else
          Bacon.more
      flush = ->
        #console.log "flushing", _.toString(resultStream)
        reply = flushWhileTriggers()
        if ends
          ends = false
          if  _.all(sources, cannotSync) or _.all(pats, cannotMatch)
            reply = Bacon.noMore
            sink end()
        unsubAll() if reply == Bacon.noMore
        #console.log "flushed"
        reply
      source.subscribe (e) ->
        if e.isEnd()
          ends = true
          source.markEnded()
          flushLater()
        else if e.isError()
          reply = sink e
        else
          source.push e.value
          if source.sync
            #console.log "queuing", e.toString(), _.toString(resultStream)
            triggers.push {source: source, e: e}
            if needsBarrier or UpdateBarrier.hasWaiters() then flushLater() else flush()
        unsubAll() if reply == Bacon.noMore
        reply or Bacon.more

    compositeUnsubscribe (part s for s in sources)...

containsDuplicateDeps = (observables, state = []) ->
  checkObservable = (obs) ->
    if _.contains(state, obs)
      true
    else
      deps = obs.internalDeps()
      if deps.length
        state.push(obs)
        _.any(deps, checkObservable)
      else
        state.push(obs)
        false

  _.any observables, checkObservable

Bacon.update = (initial, patterns...) ->
  lateBindFirst = (f) -> (args...) -> (i) -> f([i].concat(args)...)
  i = patterns.length - 1
  while (i > 0)
    unless patterns[i] instanceof Function
      patterns[i] = do (x = patterns[i]) -> (-> x)
    patterns[i] = lateBindFirst patterns[i]
    i = i - 2
  withDescription(Bacon, "update", initial, patterns..., Bacon.when(patterns...).scan initial, ((x,f) -> f x))

compositeUnsubscribe = (ss...) ->
  new CompositeUnsubscribe(ss).unsubscribe

class CompositeUnsubscribe
  constructor: (ss = []) ->
    @unsubscribed = false
    @subscriptions = []
    @starting = []
    @add s for s in ss
  add: (subscription) ->
    return if @unsubscribed
    ended = false
    unsub = nop
    @starting.push subscription
    unsubMe = =>
      return if @unsubscribed
      ended = true
      @remove unsub
      _.remove subscription, @starting
    unsub = subscription @unsubscribe, unsubMe
    @subscriptions.push unsub unless (@unsubscribed or ended)
    _.remove subscription, @starting
    unsub
  remove: (unsub) ->
    return if @unsubscribed
    unsub() if (_.remove unsub, @subscriptions) != undefined
  unsubscribe: =>
    return if @unsubscribed
    @unsubscribed = true
    s() for s in @subscriptions
    @subscriptions = []
    @starting = []
  count: ->
    return 0 if @unsubscribed
    @subscriptions.length + @starting.length
  empty: ->
    @count() == 0

Bacon.CompositeUnsubscribe = CompositeUnsubscribe

class Some
  constructor: (@value) ->
  getOrElse: -> @value
  get: -> @value
  filter: (f) ->
    if f @value
      new Some(@value)
    else
      None
  map: (f) ->
    new Some(f @value)
  forEach: (f) ->
    f @value
  isDefined: true
  toArray: -> [@value]
  inspect: -> "Some(" + @value + ")"
  toString: -> @inspect()

None = {
  getOrElse: (value) -> value
  filter: -> None
  map: -> None
  forEach: ->
  isDefined: false
  toArray: -> []
  inspect: -> "None"
  toString: -> @inspect()
}

UpdateBarrier = (->
  rootEvent = undefined
  waiterObs = []
  waiters = {}
  afters = []
  
  afterTransaction = (f) ->
    if rootEvent
      afters.push(f)
    else
      f()

  whenDoneWith = (obs, f) ->
    if rootEvent
      obsWaiters = waiters[obs.id]
      if !obsWaiters?
        obsWaiters = waiters[obs.id] = [f]
        waiterObs.push(obs)
      else
        obsWaiters.push(f)
    else
      f()

  flush = ->
    while waiterObs.length > 0
      flushWaiters(0)
    undefined

  flushWaiters = (index) ->
    obs = waiterObs[index]
    obsId = obs.id
    obsWaiters = waiters[obsId]
    waiterObs.splice(index, 1)
    delete waiters[obsId]
    flushDepsOf(obs)
    for f in obsWaiters
      f()
    undefined

  flushDepsOf = (obs) ->
    deps = obs.internalDeps()
    for dep in deps
      flushDepsOf(dep)
      if waiters[dep.id]
        index = _.indexOf(waiterObs, dep)
        flushWaiters(index)
    undefined

  inTransaction = (event, context, f, args) ->
    if rootEvent
      #console.log "in tx"
      f.apply(context, args)
    else
      #console.log "start tx"
      rootEvent = event
      result = f.apply(context, args)
      #console.log("done with tx")
      flush()
      rootEvent = undefined
      while (afters.length)
        theseAfters = afters
        afters = []
        for f in theseAfters
          f()
      result

  currentEventId = -> if rootEvent then rootEvent.id else undefined

  wrappedSubscribe = (obs, sink) ->
    unsubd = false
    doUnsub = ->
    unsub = ->
      unsubd = true
      doUnsub()
    doUnsub = obs.dispatcher.subscribe (event) ->
      afterTransaction ->
        unless unsubd
          reply = sink event
          if reply == Bacon.noMore
            unsub()
    unsub

  hasWaiters = -> waiterObs.length > 0

  { whenDoneWith, hasWaiters, inTransaction, currentEventId, wrappedSubscribe }
)()

Bacon.EventStream = EventStream
Bacon.Property = Property
Bacon.Observable = Observable
Bacon.Bus = Bus
Bacon.Initial = Initial
Bacon.Next = Next
Bacon.End = End
Bacon.Error = Error

nop = ->
latterF = (_, x) -> x()
former = (x, _) -> x
initial = (value) -> new Initial(_.always(value))
next = (value) -> new Next(_.always(value))
end = -> new End()
# instanceof more performant than x.?isEvent?()
toEvent = (x) -> if x instanceof Event then x else next x
cloneArray = (xs) -> xs.slice(0)
assert = (message, condition) -> throw new Exception(message) unless condition
assertEventStream = (event) -> throw new Exception("not an EventStream : " + event) unless event instanceof EventStream
assertFunction = (f) -> assert "not a function : " + f, isFunction(f)
isFunction = (f) -> typeof f == "function"
isArray = (xs) -> xs instanceof Array
isObservable = (x) -> x instanceof Observable
assertArray = (xs) -> throw new Exception("not an array : " + xs) unless isArray(xs)
assertNoArguments = (args) -> assert "no arguments supported", args.length == 0
assertString = (x) -> throw new Exception("not a string : " + x) unless typeof x == "string"
partiallyApplied = (f, applied) ->
  (args...) -> f((applied.concat(args))...)
makeSpawner = (args) ->
  if args.length == 1 and isObservable(args[0])
    _.always(args[0])
  else
    makeFunctionArgs args
makeFunctionArgs = (args) ->
  args = Array.prototype.slice.call(args)
  makeFunction_(args...)
makeFunction_ = withMethodCallSupport (f, args...) ->
  if isFunction f
    if args.length then partiallyApplied(f, args) else f
  else if isFieldKey(f)
    toFieldExtractor(f, args)
  else
    _.always f

makeFunction = (f, args) ->
  makeFunction_(f, args...)

makeObservable = (x) ->
  if (isObservable(x))
    x
  else
    Bacon.once(x)
isFieldKey = (f) ->
  (typeof f == "string") and f.length > 1 and f.charAt(0) == "."
Bacon.isFieldKey = isFieldKey
toFieldExtractor = (f, args) ->
  parts = f.slice(1).split(".")
  partFuncs = _.map(toSimpleExtractor(args), parts)
  (value) ->
    for f in partFuncs
      value = f(value)
    value
toSimpleExtractor = (args) -> (key) -> (value) ->
  unless value?
    undefined
  else
    fieldValue = value[key]
    if isFunction(fieldValue)
      fieldValue.apply(value, args)
    else
      fieldValue

toFieldKey = (f) ->
  f.slice(1)
toCombinator = (f) ->
  if isFunction f
    f
  else if isFieldKey f
    key = toFieldKey(f)
    (left, right) ->
      left[key](right)
  else
    assert "not a function or a field key: " + f, false

toOption = (v) ->
  if v instanceof Some or v == None
    v
  else
    new Some(v)

_ = {
  indexOf: if Array :: indexOf
    (xs, x) -> xs.indexOf(x)
  else
    (xs, x) ->
      for y, i in xs
        return i if x == y
      -1
  indexWhere: (xs, f) ->
    for y, i in xs
      return i if f(y)
    -1
  head: (xs) -> xs[0]
  always: (x) -> (-> x)
  negate: (f) -> (x) -> !f(x)
  empty: (xs) -> xs.length == 0
  tail: (xs) -> xs[1...xs.length]
  filter: (f, xs) ->
    filtered = []
    for x in xs
      filtered.push(x) if f(x)
    filtered
  map: (f, xs) ->
    f(x) for x in xs
  each: (xs, f) ->
    for key, value of xs
      f(key, value)
    undefined
  toArray: (xs) -> if isArray(xs) then xs else [xs]
  contains: (xs, x) -> _.indexOf(xs, x) != -1
  id: (x) -> x
  last: (xs) -> xs[xs.length - 1]
  all: (xs, f = _.id) ->
    for x in xs
      return false unless f(x)
    return true
  any: (xs, f = _.id) ->
    for x in xs
      return true if f(x)
    return false
  without: (x, xs) ->
    _.filter(((y) -> y != x), xs)
  remove: (x, xs) ->
    i = _.indexOf(xs, x)
    if i >= 0
      xs.splice(i, 1)
  fold: (xs, seed, f) ->
    for x in xs
      seed = f(seed, x)
    seed
  flatMap: (f, xs) ->
    _.fold xs, [], ((ys, x) ->
      ys.concat(f(x)))
  cached: (f) ->
    value = None
    ->
      if value == None
        value = f()
        f = undefined
      value
  toString: (obj) ->
    try
      recursionDepth++
      unless obj?
        "undefined"
      else if isFunction(obj)
        "function"
      else if isArray(obj)
        return "[..]" if recursionDepth > 5
        "[" + _.map(_.toString, obj).toString() + "]"
      else if obj?.toString? and obj.toString != Object.prototype.toString
        obj.toString()
      else if (typeof obj == "object")
        return "{..}" if recursionDepth > 5
        internals = for own key of obj
          value = try
            obj[key]
          catch ex
            ex
          _.toString(key) + ":" + _.toString(value)
        "{" + internals + "}"
      else
        obj
    finally
      recursionDepth--
}

recursionDepth = 0

Bacon._ = _

Bacon.scheduler = {
  setTimeout: (f,d) -> setTimeout(f,d)
  setInterval: (f, i) -> setInterval(f, i)
  clearInterval: (id) -> clearInterval(id)
  now: -> new Date().getTime()
}

if define? and define.amd?
  define [], -> Bacon
  @Bacon = Bacon
else if module? and module.exports?
  module.exports = Bacon # for Bacon = require 'baconjs'
  Bacon.Bacon = Bacon # for {Bacon} = require 'baconjs'
else
  @Bacon = Bacon # otherwise for execution context
