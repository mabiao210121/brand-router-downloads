-- Fresh-device setup. JSON comes from stdin; never accepts a shell command.
-- Existing deployments are deliberately left intact by repeated installers.
local json=require 'luci.jsonc'
local fs=require 'nixio.fs'
local util=require 'brand_router.util'
local function run(cmd) assert(util.exec(cmd),'setup_command_failed') end
local root='/etc/brand-router'
assert(require('nixio').getuid()==0,'root_required')
if fs.lstat(root) then
    local valid=pcall(function()
        assert(fs.lstat(root).type=='dir')
        local completed=json.parse(util.read(root..'/setup-complete.json',4096) or '')
        assert(type(completed)=='table' and completed.schema==1 and type(completed.key_id)=='string' and
            #completed.key_id<=64 and completed.key_id:match('^[A-Za-z0-9_-]+$'))
        local portal=json.parse(util.read(root..'/portal.json',4096) or '')
        local site=json.parse(util.read(root..'/site.json',4096) or '')
        require('brand_router.portal').listen(portal,site)
        assert(portal.customer_username==completed.username and portal.origin==completed.origin)
        for _,name in ipairs({'setup-complete.json','portal.json','site.json','portal.crt','portal.key','trust/'..completed.key_id..'.pub'}) do
            local stat=fs.lstat(root..'/'..name)
            assert(stat and stat.type=='reg' and #(util.read(root..'/'..name,8192) or '')>0)
        end
        local user=(util.capture('uci -q get rpcd.brand_customer.username',256) or ''):match('^%s*(.-)%s*$')
        local role=(util.capture('uci -q get rpcd.brand_customer.read',256) or ''):match('^%s*(.-)%s*$')
        local password=util.capture('uci -q get rpcd.brand_customer.password',2048) or ''
        assert(user==completed.username and role=='brand-router-customer' and password:match('^%$6%$'))
        local cert=util.capture('openssl x509 -in '..root..'/portal.crt -pubkey -noout 2>/dev/null',8192)
        local key=util.capture('openssl pkey -in '..root..'/portal.key -pubout 2>/dev/null',8192)
        assert(cert and #cert>0 and cert==key)
        assert(util.exec('openssl x509 -in '..root..'/portal.crt -checkend 0 -noout >/dev/null 2>&1'))
        local issuer=util.capture('openssl pkey -pubin -in '..util.quote(root..'/trust/'..completed.key_id..'.pub')..
            ' -text -noout 2>/dev/null',4096) or ''
        assert(issuer:find('ED25519'))
    end)
    assert(valid,'existing_brand_setup_incomplete; preserve_state_and_repair_before_retry')
    -- Applying an update must load the new backend while retaining all state.
    run('/etc/init.d/brand-portal restart')
    run('/etc/init.d/brand-portal running')
    run('/etc/init.d/brand-portal enable')
    io.write('{"already_initialized":true,"portal_restarted":true}\n');os.exit(0)
end
assert(not util.exec('uci -q get rpcd.brand_customer >/dev/null'),'customer_account_already_exists')
local raw=io.read(16385) or ''
assert(#raw<=16384,'setup_document_too_large')
local input=json.parse(raw)
assert(type(input)=='table','setup_document_required')
local key=input.trust
assert(type(key)=='table' and type(key.key_id)=='string' and #key.key_id<=64 and
    key.key_id:match('^[A-Za-z0-9_-]+$') and type(key.public_key_pem)=='string' and
    #key.public_key_pem<4096 and not key.public_key_pem:find('PRIVATE'),'public_issuer_key_required')
local username=input.username or 'client'
assert(type(username)=='string' and #username>=1 and #username<=48 and username~='root' and
    username:match('^[A-Za-z0-9_.-]+$'),'invalid_customer_username')
local password=input.password or util.random_hex(16)
assert(type(password)=='string' and #password>=12 and #password<=128 and
    not password:find('[%z\r\n]'),'invalid_customer_password')
local brand=input.brand_name or '工控机管理系统'
assert(type(brand)=='string' and #brand>=1 and #brand<=120,'invalid_brand_name')
local lan=json.parse(util.capture('ubus call network.interface.lan status',16384) or '')
local addresses=lan and lan['ipv4-address']
assert(type(addresses)=='table' and #addresses==1,'one_lan_ipv4_required')
local ip=addresses[1].address
assert(type(ip)=='string' and ip:match('^%d+%.%d+%.%d+%.%d+$'),'invalid_lan_address')
local port=28283
-- Reject port conflicts before changing account or files.
local sockets=util.capture('netstat -lnt',65536) or ''
assert(not sockets:find(':'..port..'%s'),'portal_port_in_use')
local origin='https://'..ip..':'..port
local backup=assert(util.read('/etc/config/rpcd',65536),'rpcd_config_required')
local tmp=util.tempdir('/tmp');local created=false;local account_changed=false
local files={'portal.json','site.json','portal.crt','portal.key','setup-complete.json','trust/'..key.key_id..'.pub','state/panel-account.json'}
local ok,result=pcall(function()
    run('mkdir -m 700 '..root)
    created=true
    run('mkdir -m 700 '..root..'/trust')
    util.write(root..'/trust/'..key.key_id..'.pub',key.public_key_pem)
    local description=util.capture('openssl pkey -pubin -in '..util.quote(root..'/trust/'..key.key_id..'.pub')..' -text -noout 2>/dev/null',4096) or ''
    assert(description:find('ED25519'),'ed25519_public_key_required')
    util.write(tmp..'/password',password..'\n')
    local hashed=util.capture('openssl passwd -6 -stdin < '..util.quote(tmp..'/password'),2048)
    hashed=hashed and hashed:match('^%s*(.-)%s*$')
    assert(hashed and hashed:match('^%$6%$[A-Za-z0-9./$]+$'),'password_hash_failed')
    fs.unlink(tmp..'/password')
    util.write(tmp..'/account',"set rpcd.brand_customer=login\nset rpcd.brand_customer.username='"..username..
        "'\nset rpcd.brand_customer.password='"..hashed.."'\nadd_list rpcd.brand_customer.read='brand-router-customer'\ncommit rpcd\n")
    util.write(root..'/portal.json',json.stringify({enabled=true,brand_name=brand,customer_username=username,origin=origin,listen=ip..':'..port}))
    util.write(root..'/site.json',json.stringify({enforcement_enabled=false,brand_port=port}))
    run('openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout '..root..
        '/portal.key -out '..root..'/portal.crt -days 3650 -subj /CN=BrandRouter-local -addext '..
        util.quote('subjectAltName=IP:'..ip)..' >/dev/null 2>&1')
    run('chmod 600 '..root..'/portal.key')
    account_changed=true
    run('uci batch < '..util.quote(tmp..'/account'))
    run('/etc/init.d/rpcd reload')
    local account=require('brand_router.panel_account').initialize({state_dir=root..'/state',temp_parent='/tmp',openssl='/usr/bin/openssl'})
    run('/etc/init.d/brand-portal start')
    run('/etc/init.d/brand-portal running')
    run('/etc/init.d/brand-portal enable')
    util.atomic(root..'/setup-complete.json',json.stringify({schema=1,username=username,
        key_id=key.key_id,origin=origin}))
    return {installed=true,portal_url=origin,username=account.username,password='',recovery_code=account.recovery_code,first_setup=true,activation_required=true,
        certificate='self-signed LAN certificate',proxy_runtime_connected=false}
end)
util.cleanup(tmp,{'password','account'})
if not ok then
    if created then
        pcall(function() require('brand_router.local_entry').remove() end)
        util.exec('/etc/init.d/brand-portal stop >/dev/null 2>&1')
        util.exec('/etc/init.d/brand-portal disable >/dev/null 2>&1')
        for _,name in ipairs(files) do fs.unlink(root..'/'..name) end
        fs.rmdir(root..'/trust');fs.rmdir(root..'/state');fs.rmdir(root)
    end
    if account_changed then util.atomic('/etc/config/rpcd',backup);util.exec('/etc/init.d/rpcd reload') end
    io.stderr:write('fresh_panel_setup_failed; original account configuration restored\n');os.exit(1)
end
io.write(json.stringify(result)..'\n')
