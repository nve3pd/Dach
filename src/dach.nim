## Dach is tiny web application framework. This project started with SecHack365.
##
## Example
## -------
## This example will create an Dach application on 127.0.0.1:8080
##
## .. code-block::nim
##    import dach
##    var app = newDach()
##    
##    proc cb(ctx: DachCtx): Resp =
##       ctx.response("Hello World")
##    
##    app.addRoute("/", "index")
##    app.addView("index", HttpGet, cb)
##
##    app.run()
##

import asyncdispatch, uri, httpcore, cookies
import strformat, strutils
import tables, strtabs
import macros
import db_mysql

import nest

import dach/[route, response, configrator, logger, cookie, session]

when useHttpBeast:
  import options
  import httpbeast
else:
  import asynchttpserver

#include dach/cookie
#include dach/response

export cookie, response, httpcore, session, route
export tables
#export route except get

type
  Dach* = ref object
    router*: Router[CallBack]
    config: Configurator
    routeNames: Table[string, string]
    #session*: StringTableRef

proc newDach*(filename: string = ""): Dach =
  ## Create a new Dach instance
  result = new Dach

  result.router = newDachRouter()
  result.routeNames = initTable[string, string]()
  result.config = newConfigurator()

#  if filename == "":
#    result.config = newConfigurator()
#  else:
#    result.config = loadConfigFile(filename)
#
#  if result.config.isUseSession:
#    let
#      con = result.config.sessionConnection
#      user = result.config.sessionServerUser
#      pass = result.config.sessionServerPassword
#      database = result.config.sessionServerDatabase
#    result.session = newSession(con, user, pass, database)

proc addRoute*(r: var Dach, rule, name: string) =
  ## Add route and route name
  r.routeNames[name] = rule

proc addView*(r: var Dach, name: string, hm: HttpMethod, cb: CallBack) =
  ## Add CallBack based on route name
  ##
  ## .. code-block::nim
  ##    import dach
  ##    var app = newDach()
  ##    
  ##    proc cb(ctx: DachCtx): Resp =
  ##       ctx.response("Hello World")
  ##    
  ##    app.addRoute("/", "index")
  ##    app.addView("index", HttpGet, cb)
  ##
  ##    app.run()
  if not r.routeNames.hasKey(name):
    return
    # raise exception
  let rule = r.routeNames[name]
  r.router.addRule(rule, hm, cb)

proc parseBodyQuery(s: string): StringTableRef =
  result = newStringTable()
  if s != "":
    for query in s.split("&"):
      let param = query.split("=")
      result[param[0]] = param[1]

proc createDachCtx(req: Request): DachCtx =
  result = newDachCtx()
  when useHttpBeast:
    result.uri = parseUri(req.path.get())
    result.httpmethod = req.httpMethod.get()
    result.bodyQuery = parseBodyQuery(req.body.get())
    let header = req.headers.get()
    if header.hasKey("cookie"):
      result.cookie = parseCookies(header["cookie"]) 
    else:
      result.cookie = newStringTable()
  else:
    result.uri = parseUri(req.url.path)
    result.httpmethod = req.reqMethod
    result.bodyQuery = parseBodyQuery(req.body)
  result.req = req

proc toString(headers: HttpHeaders): string =
  result = ""
  for i in headers.pairs:
    result &= i.key & ":" & i.value
    result &= "\c\L"
  result = result.strip()

proc run*(r: Dach) =
  ## running Dach application.
  r.router.compress()
  let
    port = r.config.port
    address = r.config.address

  if r.config.debug == true:
    dachConsoleLogger()

  when useHttpBeast:
    let settings = httpbeast.initSettings(Port(port))
    proc handler(req: Request): Future[void] =
      var 
        ctx = createDachCtx(req)
        res = r.router.route(($ctx.httpmethod).toLower, ctx.uri)
      ctx.form = res.arguments.queryArgs
      echo res.arguments.queryArgs
      ctx.pathQuery = res.arguments.pathArgs

      if res.status == routingSuccess:
        let
          resp = res.handler(ctx)
          body = resp.content.content
          mimetype = resp.content.mimetype
        var header = resp.headers
        header["Content-Type"] = mimetype
        header["Set-Cookie"] = resp.cookie.concat()
        info(fmt"{$ctx.httpmethod} {ctx.uri} {$resp.statuscode}")
        req.send(resp.statuscode, body, header.toString())
      else:
        info(fmt"{$ctx.httpmethod} {ctx.uri} {Http404}")
        req.send(Http404, "NOT FOUND")

    echo fmt"Running on {address}:{port} with httpbeast"
    httpbeast.run(handler, settings)
  else:
    let server = newAsyncHttpServer()
    proc handler(req: Request) {.async.} =
      let
        ctx = createDachCtx(req)
        res = r.router.route(($ctx.httpmethod).toLower, ctx.uri)

      if res.status == routingSuccess:
        let
          resp = res.handler(ctx)
          body = resp.content.content
          mimetype = resp.content.mimetype
        var header = resp.headers
        header["Content-Type"] = mimetype
        header["Set-Cookie"] = resp.cookie.concat()
        info(fmt"{$ctx.httpmethod} {ctx.uri} {$resp.statuscode}")
        await req.respond(resp.statuscode, body, header)
      else:
        info(fmt"{$ctx.httpmethod} {ctx.uri} {Http404}")
        await req.respond(Http404, "Not Found")

    echo fmt"Running on {address}:{port} with asynchttpserver"
    waitFor server.serve(port=Port(port), handler, address=address)

