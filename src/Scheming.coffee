root = @

isNode = typeof exports != 'undefined' && typeof module != 'undefined' && module.exports

if isNode
  _ = require 'lodash'

uuid = ->
  now = Date.now()
  'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace /[xy]/g, (c) ->
    r = (now + Math.random() * 16) % 16 | 0
    now = Math.floor now / 16
    ((if c is "x" then r else (r & 0x7 | 0x8))).toString 16

RESERVED_PROPERTIES =
  validate : 'validate'

TYPES =
  String  :
    ctor       : String
    string     : 'string'
    identifier : _.isString
    parser     : (val) ->
      '' + val
  Number  :
    ctor       : Number
    string     : 'number'
    identifier : _.isNumber
    parser     : parseFloat
  Integer :
    string     : 'integer'
    identifier : (val) ->
      _.isNumber(val) && val % 1 == 0
    parser     : parseInt
  Float   :
    string     : 'float'
    identifier : _.isNumber
    parser     : parseFloat
  Date    :
    ctor       : Date
    string     : 'date'
    identifier : _.isDate
    parser     : (val) ->
      new Date val
  Boolean :
    ctor       : Boolean
    string     : 'boolean'
    identifier : _.isBoolean
    parser     : (val) ->
      !!val
  Mixed   :
    ctor       : (val) ->
      val
    string     : '*'
    identifier : ->
      true
    parser     : _.identity

# parsers for nested types are dynamic and must be built at resolution time
NESTED_TYPES =
  Array  :
    ctor        : Array
    string      : 'array'
    identifier  : _.isArray
    childType   : null
    parser      : _.toArray
    childParser : _.toArray
  Schema :
    ctor       : Object
    string     : 'schema'
    identifier : null
    childType  : null
    parser     : null

getPrimitiveTypeOf = (type) ->
  for k, TYPE of TYPES
    if type == TYPE or
        (TYPE.ctor && type == TYPE.ctor) or
        type?.toLowerCase?() == TYPE.string

      return TYPE

  return null

Scheming = {TYPES, NESTED_TYPES, RESERVED_PROPERTIES}

Scheming.resolveType = (typeDef) ->
  type = getPrimitiveTypeOf typeDef

  if !type?
    if _.isArray typeDef
      type = _.cloneDeep NESTED_TYPES.Array
      childType = TYPES.Mixed

      if typeDef.length
        childType = Scheming.resolveType(typeDef[0])

      type.childType = childType
      type.childParser = (val) ->
        for index, member of val
          if !childType.identifier(member)
            val[index] = childType.parser(member)

        return val

    resolveSchemaType = (type, childType) ->
      type.childType = childType
      type.identifier = (val) ->
        return val instanceof childType
      type.parser = (val) ->
        return new childType(val)

    if _.isPlainObject typeDef
      type = _.cloneDeep NESTED_TYPES.Schema
      childType = Scheming.create typeDef
      resolveSchemaType type, childType

    if _.isFunction(typeDef) && typeDef.__skemaId
      type = _.cloneDeep NESTED_TYPES.Schema
      childType = typeDef
      resolveSchemaType type, childType

    if _.isString(typeDef) && typeDef[...7] == 'Schema:'
      type = _.cloneDeep NESTED_TYPES.Schema
      childType = typeDef[7..]
      for fn in ['identifier', 'parser']
        do (fn) ->
          type[fn] = (val) ->
            childType = Scheming.get childType
            if !childType
              throw new Error "Error resolving #{typeDef} on lazy initialization"
            resolveSchemaType type, childType

            return type[fn] val

  return type || null

Scheming.normalizeProperty = (config, fieldName) ->
  definition =
    type       : null
    default    : null
    getter     : null
    setter     : null
    validators : null
    required   : false

  if !(_.isPlainObject(config) && config.type?)
    config = {type : config}

  {type, getter, setter, validate, required} = config

  if !type?
    throw new Error "Error resolving #{fieldName}. Schema type must be defined."
  if getter? && !_.isFunction getter
    throw new Error "Error resolving #{fieldName}. Schema getter must be a function."
  if setter? && !_.isFunction setter
    throw new Error "Error resolving #{fieldName}. Schema setter must be a function."

  validate ?= []
  if !_.isArray(validate)
    validate = [validate]
  for fn in validate
    if !_.isFunction fn
      throw new Error "Error resolving #{fieldName}. Schema validate must be a function or array of functions."

  definition.type = Scheming.resolveType type

  if !definition.type?
    throw new Error "Error resolving #{fieldName}. Unrecognized type #{type}"

  definition.default = config.default
  definition.getter = getter
  definition.setter = setter
  definition.validators = validate
  definition.required = required

  return definition

###
opts:
  strict - if false, allows attachment of arbitrary properties to object
###
## TODO: How to deal with arrays and array mutations for watching
## TODO: allowArbitrary : Object.seal - prevent adding / removing of properties
## TODO: support strict assignment, so rather than parse, throw an error?
###
  Doc notes -
   - parsers are applied before setters; setters can assume they are receiving correct type

###
# name, schemaConfig, opts
registry = {}

register = (key, value) ->
  if registry[key]
    throw new Error "Naming conflict encountered. Schema #{key} already exists"
  registry[key] = value

Scheming.create = (args...) ->
  if !_.isString(args[0])
    args.unshift uuid()

  [name, schemaConfig, opts] = args

  normalizedSchema = {}

  class Schema
    @__skemaId : name

    @defineProperties : (config) ->
      for k, v of config
        @defineProperty k, v

    @defineProperty : (fieldName, config) ->
      normalizedSchema[fieldName] = Scheming.normalizeProperty(config, fieldName)

    constructor : (model) ->
      data = {}

      Object.defineProperty @, '__skemaId',
        enumerable   : false
        configurable : false
        writable     : false
        value        : Schema.__skemaId

      for fieldName, typeDefinition of normalizedSchema
        do (fieldName, typeDefinition) =>
          {type, getter, setter} = typeDefinition

          Object.defineProperty @, fieldName,
            configurable : true
            enumerable   : true
            get          : ->
              val = data[fieldName]
              if val is undefined
                return val
              if type.string == NESTED_TYPES.Array.string
                val = type.childParser val
              if getter
                val = getter val
              return val
            set          : (val) ->
              if !type.identifier(val)
                val = type.parser val
              if setter
                val = setter val
              data[fieldName] = val

          if typeDefinition.default is not undefined
            @[fieldName] = typeDefinition.default

      for key, value of model
        @[key] = value

      @validate = () ->
        errors = {}
        # prevents infinite loops in circular references
        if @_validating then return null
        @_validating = true

        pushError = (key, err) ->
          if _.isArray err
            return pushError(key, e) for e in err
          if !_.isString err
            err = 'Validation error occurred.'
          errors[key] ?= []
          errors[key].push err

        # apply validation rules
        for key, value of normalizedSchema

          {validators, required} = value

          val = @[key]

          if required && !val?
            pushError key, "Field is required."
          if val?
            {type} = normalizedSchema[key]

            for validator in validators
              err = true
              try
                err = validator(val)
              catch e
                if e then err = e.message
              if err != true then pushError key, err

            if type.string == 'schema'
              childErrors = val.validate()
              for k, v of childErrors
                pushError "#{key}.#{k}", v
            if type.string == 'array' && type.childType.string == 'schema'
              for member, i in val
                childErrors = member.validate()
                for k, v of childErrors
                  pushError "#{key}[#{i}].#{k}", v

        @_validating = false

        if _.size(errors) == 0
          return null
        else
          return errors

  Schema.defineProperties schemaConfig

  register name, Schema

  return Schema

Scheming.get = (name) ->
  return registry[name]

Scheming.reset = ->
  registry = {}

if isNode
  module.exports = Scheming
else
  root.Scheming = Scheming