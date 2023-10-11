local class = require 'pl.class'
local TestClass = require 'test_class'
local _M = class(TestClass)

function _M:_init(strTestName, uiTestCase, tLogWriter, strLogLevel)
  self:super(strTestName, uiTestCase, tLogWriter, strLogLevel)

  local P = self.P
  self:__parameter {
    P:P('plugin', 'A pattern for the plugin to use.'):
      required(false),

    P:P('plugin_options', 'Plugin options as a JSON object.'):
      required(false)
  }
end



function _M:__validateCAL(tAttr, strData)
  local fIsValid = false
  local strError

  -- The data should have a size of 8192 bytes.
  local sizData = string.len(strData)
  if sizData~=8192 then
    strError = string.format('The page should have 8192 bytes, but it has %d.', sizData)
  else
    -- The upper and lower half of the data must be the same.
    local strData0 = string.sub(strData, 0x0000+1, 0x1000)
    local strData1 = string.sub(strData, 0x1000+1, 0x2000)
    if strData0~=strData1 then
      strError = 'The page should have the same contents in the upper and lower half, but they differ.'
    else
      local aucRomFuncModeCookie = string.char(
        0x43, 0xC4, 0xF2, 0xB2, 0x45, 0x40, 0x02, 0xC8,
        0x78, 0x79, 0xDD, 0x94, 0xF7, 0x13, 0xB5, 0x4A
      )
      if string.sub(strData0, 0x0000+1, 0x0010)~=aucRomFuncModeCookie then
        strError = 'The ROM func mode cookie is not set.'

      else
        local strAnalogParameter = string.sub(strData0, 0x0010+1, 0x005c)
        local strAnalogCrc = string.sub(strData0, 0x005c+1, 0x0060)
        local mhash = require 'mhash'
        local tCrc = mhash.mhash_state()
        tCrc:init(mhash.MHASH_CRC32B)
        tCrc:hash(strAnalogParameter)
        local strAnalogCrcMy = tCrc:hash_end()
        if strAnalogCrc~=strAnalogCrcMy then
          strError = 'The CRC of the analog parameter is not valid.'
        else

          local strEthernetParameter = string.sub(strData0, 0x0060+1, 0x0860)
          local strEthernetParameterHash = string.sub(strData0, 0x0860+1, 0x0890)
          local tHash = mhash.mhash_state()
          tHash:init(mhash.MHASH_SHA384)
          tHash:hash(strEthernetParameter)
          local strHashMy = tHash:hash_end()
          if strEthernetParameterHash~=strHashMy then
            strError = 'The hash of the ethernet parameter is invalid.'
          else

            fIsValid = true
          end
        end
      end
    end
  end

  return fIsValid, strError
end



function _M:__validateCOM_APP(tAttr, strData)
  local fIsValid = false
  local strError

  -- The data should have a size of 8192 bytes.
  local sizData = string.len(strData)
  if sizData~=8192 then
    strError = string.format('The page should have 8192 bytes, but it has %d.', sizData)
  else
    -- The upper and lower half of the data must be the same.
    local strData0 = string.sub(strData, 0x0000+1, 0x1000)
    local strData1 = string.sub(strData, 0x1000+1, 0x2000)
    if strData0~=strData1 then
      strError = 'The page should have the same contents in the upper and lower half, but they differ.'
    else
      -- The checksum must be OK.
      local strContents = string.sub(strData0, 0x0000+1, 0x0fd0)
      local strHashPage = string.sub(strData0, 0x0fd0+1, 0x1000)

      -- Test the hash sum at the end of the page.
      local mhash = require 'mhash'
      local tHash = mhash.mhash_state()
      tHash:init(mhash.MHASH_SHA384)
      tHash:hash(strContents)
      local strHashMy = tHash:hash_end()
      if strHashPage~=strHashMy then
        strError = 'The hash of the page is invalid.'
      else

        -- The page is OK.
        fIsValid = true
      end
    end
  end

  return fIsValid, strError
end



function _M:__validateKIP(tAttr, strData)
  local fIsValid = false
  local strError

  -- The data should have a size of 4096 bytes.
  local sizData = string.len(strData)
  if sizData~=4096 then
    strError = string.format('The page should have 4096 bytes, but it has %d.', sizData)
  else
    -- Check the CRC.
    local strContents = string.sub(strData, 0x0000+1, 0x0014)
    local strCrcPage = string.sub(strData, 0x0014+1, 0x0018)
    local mhash = require 'mhash'
    local tCrc = mhash.mhash_state()
    tCrc:init(mhash.MHASH_CRC32B)
    tCrc:hash(strContents)
    local strCrcMy = tCrc:hash_end()
    if strCrcPage~=strCrcMy then
      strError = 'The CRC of the KIP parameter is not valid.'
    else

      -- Check for the GDR_FP thingie.
      local strGdrFp = string.sub(strData, 0x0050+1, 0x0060)
      local strGdrFpGood = string.char(
        0xAA, 0x55, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF
      )
      if strGdrFp~=strGdrFpGood then
        strError = 'The GDR_FP field is not valid.'

      else
        fIsValid = true

      end
    end
  end

  return fIsValid, strError
end



function _M:run()
  local atParameter = self.atParameter
  local tLog = self.tLog
  local pl = self.pl

  ----------------------------------------------------------------------
  --
  -- Parse the parameters and collect all options.
  --
  local strPluginPattern = atParameter['plugin']:get()
  local strPluginOptions = atParameter['plugin_options']:get()


  ----------------------------------------------------------------------
  --
  -- Open the connection to the netX.
  -- (or re-use an existing connection.)
  --
  local atPluginOptions = {}
  if strPluginOptions~=nil then
    local json = require 'dkjson'
    local tJson, uiPos, strJsonErr = json.decode(strPluginOptions)
    if tJson==nil then
      tLog.warning('Ignoring invalid plugin options. Error parsing the JSON: %d %s', uiPos, strJsonErr)
    else
      atPluginOptions = tJson
    end
  end
  local tPlugin = _G.tester:getCommonPlugin(strPluginPattern, atPluginOptions)
  if tPlugin==nil then
    local strPluginOptionsPretty = pl.pretty.write(atPluginOptions)
    local strError = string.format(
      'Failed to establish a connection to the netX with pattern "%s" and options "%s".',
      strPluginPattern,
      strPluginOptionsPretty
    )
    error(strError)
  end


  ----------------------------------------------------------------------
  --
  -- Read all info pages.
  --
  local atInfoPages = {}
  local atEventData = {}

  -- Download the flasher binary.
  local tFlasher = require 'flasher'(tLog)
  local aAttr = tFlasher:download(tPlugin, 'netx/')

  -- Loop over all info pages.
  local atInfoPageAttributes = {
    -- CAL Page
    {
      strName = 'CAL',
      tBus = tFlasher.BUS_IFlash,
      ulUnit = 0,
      ulChipSelect = 1,
      validate = self.__validateCAL
    },
    -- KIP0 Page
    {
      strName = 'KIP0',
      tBus = tFlasher.BUS_IFlash,
      ulUnit = 0,
      ulChipSelect = 2,
      validate = self.__validateKIP
    },
    -- COM Page
    {
      strName = 'COM',
      tBus = tFlasher.BUS_IFlash,
      ulUnit = 1,
      ulChipSelect = 1,
      validate = self.__validateCOM_APP
    },
    -- KIP1 Page
    {
      strName = 'KIP1',
      tBus = tFlasher.BUS_IFlash,
      ulUnit = 1,
      ulChipSelect = 2,
      validate = self.__validateKIP
    },
    -- APP Page
    {
      strName = 'APP',
      tBus = tFlasher.BUS_IFlash,
      ulUnit = 2,
      ulChipSelect = 1,
      validate = self.__validateCOM_APP
    },
    -- KIP2 Page
    {
      strName = 'KIP2',
      tBus = tFlasher.BUS_IFlash,
      ulUnit = 2,
      ulChipSelect = 2,
      validate = self.__validateKIP
    }
  }
  for _, tFlashAttr in ipairs(atInfoPageAttributes) do
    local strName = tFlashAttr.strName
    local tBus = tFlashAttr.tBus
    local ulUnit = tFlashAttr.ulUnit
    local ulChipSelect = tFlashAttr.ulChipSelect

    tLog.info(
      'Reading "%s" (%d/%d/%d)...', strName, tBus, ulUnit, ulChipSelect)

    -- Detect the device.
    local fOk = tFlasher:detect(tPlugin, aAttr, tBus, ulUnit, ulChipSelect)
    if fOk~=true then
      tLog.error('Failed to detect the device "%s" (%d/%d/%d)...', strName, tBus, ulUnit, ulChipSelect)
      error('Failed to detect a flash.')
    end

    -- Get the size of the complete devicesize.
    local ulSize = tFlasher:getFlashSize(tPlugin, aAttr, _G.tester.callback, _G.tester.callback_progress)

    -- Read the complete flash array.
    local strData, strMessage = tFlasher:readArea(
      tPlugin, aAttr,
      0,
      ulSize,
      _G.tester.callback,
      _G.tester.callback_progress
    )
    if strData==nil then
      tLog.error('Failed to read the flash area "%s" (%d/%d/%d) : %s', strName, tBus, ulUnit, ulChipSelect, strMessage)
      error('Failed to read the flash: ' .. strMessage)
    end

    -- Store the data.
    atInfoPages[strName] = strData

    atEventData[strName] = _G.tester:asciiArmor(strData)
    atEventData['size_' .. strName] = ulSize
  end


  -- Validate all info pages.
  local fAllPagesAreValid = true
  for _, tFlashAttr in ipairs(atInfoPageAttributes) do
    local strName = tFlashAttr.strName
    local strData = atInfoPages[strName]
    local fIsValid, strMessage = tFlashAttr.validate(self, tFlashAttr, strData)
    atEventData['valid_' .. strName] = fIsValid
    atEventData['error_' .. strName] = strMessage
    fAllPagesAreValid = fAllPagesAreValid and fIsValid
    if fIsValid~=true then
      tLog.error('Failed to validate "%s": %s', strName, strMessage)
    end
  end

  -- Log the complete info page contents.
  -- Always do this even if this test thinks it is OK.
  _G.tester:sendLogEvent('muhkuh.attribute.info_pages', atEventData)

  if fAllPagesAreValid~=true then
    local json = require 'dkjson'
    tLog.error('Failed to validate the info pages: %s', json.encode(atEventData))
    error('Failed to validate the info pages.')
  end

  print("")
  print(" #######  ##    ## ")
  print("##     ## ##   ##  ")
  print("##     ## ##  ##   ")
  print("##     ## #####    ")
  print("##     ## ##  ##   ")
  print("##     ## ##   ##  ")
  print(" #######  ##    ## ")
  print("")
end


return _M
