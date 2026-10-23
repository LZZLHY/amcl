/**
 * 组 schema v4 的严格 NAPI 编解码及必要离散通知。由 napi_input.cpp 在具名读取 helper
 * 定义后包含，仍属于同一 libentry 边界；不注册第二个输入生产者或独立维护时钟。
 */
static bool GroupProducerCurrent(uint64_t identity);
static bool GroupFields(napi_env env, napi_value value, const std::set<std::string>& allowed) {
    napi_value names = nullptr; uint32_t count = 0;
    if (napi_get_property_names(env,value,&names) != napi_ok || napi_get_array_length(env,names,&count) != napi_ok || count > allowed.size()) return false;
    for (uint32_t i = 0; i < count; ++i) {
        napi_value name = nullptr; std::string text;
        if (napi_get_element(env,names,i,&name) != napi_ok || !ReadBoundedUtf8String(env,name,64,text) || !allowed.count(text)) return false;
    }
    return true;
}
static bool GroupArray(napi_env env,napi_value object,const char* name,uint32_t maximum,napi_value* out,uint32_t* count) {
    bool array = false;
    return NamedValue(env,object,name,out) && napi_is_array(env,*out,&array) == napi_ok && array &&
        napi_get_array_length(env,*out,count) == napi_ok && *count <= maximum;
}
static bool GroupText(napi_env env,napi_value object,const char* name,size_t maximum,std::string& text) {
    napi_value value = nullptr;
    return NamedValue(env,object,name,&value) && ReadBoundedUtf8String(env,value,maximum,text) && text.find('\0') == std::string::npos;
}

/** 所有长度与枚举先验再分配；原 v3 解析器不会碰到扩展，也不能误接受 v4 的半份表。 */
static bool ReadGroupSchema(napi_env env,napi_value root,uint32_t controlCount,amcl::input::TouchGroupSchema& result) {
    napi_value object = nullptr, groups = nullptr, controls = nullptr; uint32_t count = 0;
    if (!NamedValue(env,root,"groupSchema",&object) || !GroupFields(env,object,{"profile","groups","controls"}) ||
        !GroupText(env,object,"profile",192,result.profile) ||
        !GroupArray(env,object,"groups",amcl::input::kMaxTouchGroups,&groups,&count)) return false;
    for (uint32_t i = 0; i < count; ++i) {
        napi_value group = nullptr; amcl::input::TouchGroupDefinition value;
        if (napi_get_element(env,groups,i,&group) != napi_ok || !GroupFields(env,group,{"id","initialVisible"}) ||
            !GroupText(env,group,"id",23,value.id) || !NamedBool(env,group,"initialVisible",&value.initialVisible)) return false;
        result.groups.push_back(std::move(value));
    }
    if (!GroupArray(env,object,"controls",AMCL_CONTROL_SCHEMA_MAX_CONTROLS,&controls,&count) ||
        count != (result.Enabled() ? controlCount : 0)) return false;
    size_t total = 0;
    for (uint32_t i = 0; i < count; ++i) {
        napi_value control = nullptr, phases = nullptr; uint32_t phaseCount = 0; amcl::input::TouchGroupControl value;
        if (napi_get_element(env,controls,i,&control) != napi_ok ||
            !GroupFields(env,control,{"group","phases","fcl","mouseTool","rank","bindings"}) ||
            !NamedInt(env,control,"group",&value.group) || !NamedInt(env,control,"rank",&value.rank) ||
            !NamedBool(env,control,"phases",&value.phases) || !NamedBool(env,control,"fcl",&value.fcl) ||
            !NamedBool(env,control,"mouseTool",&value.mouseTool) ||
            !GroupArray(env,control,"bindings",4,&phases,&phaseCount) || phaseCount != 4) return false;
        for (uint32_t p = 0; p < 4; ++p) {
            napi_value phase = nullptr, keys = nullptr, actions = nullptr; uint32_t keyCount = 0, actionCount = 0;
            auto& binding = value.bindings[p];
            if (napi_get_element(env,phases,p,&phase) != napi_ok || !GroupFields(env,phase,{"keys","autoKeep","actions"}) ||
                !NamedBool(env,phase,"autoKeep",&binding.autoKeep) || !GroupArray(env,phase,"keys",6,&keys,&keyCount) ||
                !GroupArray(env,phase,"actions",amcl::input::kMaxTouchGroupTargets,&actions,&actionCount)) return false;
            total += actionCount; if (total > amcl::input::kMaxTouchGroupOperations) return false;
            for (uint32_t k = 0; k < keyCount; ++k) {
                napi_value key = nullptr; int32_t code = 0;
                if (napi_get_element(env,keys,k,&key) != napi_ok || !StrictInt(env,key,&code)) return false;
                binding.keys.push_back(code);
            }
            for (uint32_t a = 0; a < actionCount; ++a) {
                napi_value action = nullptr; int32_t target = -1, operation = -1;
                if (napi_get_element(env,actions,a,&action) != napi_ok || !GroupFields(env,action,{"target","operation"}) ||
                    !NamedInt(env,action,"target",&target) || target < 0 || !NamedInt(env,action,"operation",&operation) || operation < 0 || operation > 2) return false;
                binding.actions.push_back({static_cast<uint32_t>(target),static_cast<amcl::input::TouchGroupOperation>(operation)});
            }
            if (!value.phases && binding.Active()) return false;
        }
        result.controls.push_back(std::move(value));
    }
    return amcl::input::ValidTouchGroupSchema(result,controlCount);
}

static bool GroupSetText(napi_env env,napi_value object,const char* name,const std::string& text) {
    napi_value value = nullptr;
    return napi_create_string_utf8(env,text.data(),text.size(),&value) == napi_ok && napi_set_named_property(env,object,name,value) == napi_ok;
}
static bool GroupSetBool(napi_env env,napi_value object,const char* name,bool flag) {
    napi_value value = nullptr;
    return napi_get_boolean(env,flag,&value) == napi_ok && napi_set_named_property(env,object,name,value) == napi_ok;
}

/** 恢复初始态与控件动作返回同一终态协议；false不能同时表示暂拒和已过期。 */
static napi_value GroupCommandReceipt(napi_env env,const amcl::input::TouchGroupResult& receipt) {
    const char* statuses[] = {"pending","committed","presented","stale","rejected","expired"};
    napi_value result = nullptr;
    if (napi_create_object(env,&result) != napi_ok || !GroupSetText(env,result,"status",statuses[static_cast<size_t>(receipt.status)]) ||
        !GroupSetText(env,result,"revision",std::to_string(receipt.revision))) return amcl::napi::MakeUndefined(env);
    return result;
}

napi_value ReadTouchGroups(napi_env env,napi_callback_info info) {
    size_t argc = 1; napi_value args[1]{}; uint64_t token = 0;
    napi_get_cb_info(env,info,&argc,args,nullptr,nullptr);
    if (argc != 1 || !ReadTouchIdentity(env,args[0],&token)) return amcl::napi::MakeUndefined(env);
    try {
        const auto state = amcl::input::ReadTouchGroups(token); napi_value result = nullptr, mask = nullptr, epochs = nullptr;
        if (napi_create_object(env,&result) != napi_ok || !GroupSetText(env,result,"token",std::to_string(state.token)) ||
            !GroupSetText(env,result,"revision",std::to_string(state.revision)) || !GroupSetBool(env,result,"enabled",state.enabled) ||
            !GroupSetBool(env,result,"pending",state.pending) || napi_create_array_with_length(env,state.mask.size(),&mask) != napi_ok ||
            napi_create_array_with_length(env,state.epochs.size(),&epochs) != napi_ok) return amcl::napi::MakeUndefined(env);
        for (size_t i = 0; i < state.mask.size(); ++i) {
            napi_value flag = nullptr, epoch = nullptr; const std::string identity = std::to_string(state.epochs[i]);
            if (napi_get_boolean(env,state.mask[i] != 0,&flag) != napi_ok || napi_set_element(env,mask,i,flag) != napi_ok ||
                napi_create_string_utf8(env,identity.data(),identity.size(),&epoch) != napi_ok || napi_set_element(env,epochs,i,epoch) != napi_ok)
                return amcl::napi::MakeUndefined(env);
        }
        if (napi_set_named_property(env,result,"mask",mask) != napi_ok || napi_set_named_property(env,result,"epochs",epochs) != napi_ok)
            return amcl::napi::MakeUndefined(env);
        return result;
    } catch (...) { return amcl::napi::MakeUndefined(env); }
}

napi_value ConfirmTouchGroups(napi_env env,napi_callback_info info) {
    size_t argc = 2; napi_value args[2]{}; uint64_t token = 0, revision = 0;
    napi_get_cb_info(env,info,&argc,args,nullptr,nullptr);
    return amcl::napi::MakeBoolResult(env,argc == 2 && ReadTouchIdentity(env,args[0],&token) &&
        ReadTouchIdentity(env,args[1],&revision) && amcl::input::ConfirmTouchGroups(token,revision));
}

napi_value IsTouchGroupControlCurrent(napi_env env,napi_callback_info info) {
    size_t argc = 3; napi_value args[3]{}; uint64_t token = 0, epoch = 0; std::string control;
    napi_get_cb_info(env,info,&argc,args,nullptr,nullptr);
    return amcl::napi::MakeBoolResult(env,argc == 3 && ReadTouchIdentity(env,args[0],&token) &&
        ReadBoundedUtf8String(env,args[1],23,control) && ReadTouchIdentity(env,args[2],&epoch) &&
        amcl::input::AcceptTouchGroupControl(token,control,epoch));
}

napi_value BindTouchGroupMouseOwner(napi_env env,napi_callback_info info) {
    size_t argc=3; napi_value args[3]{}; uint64_t token=0,epoch=0; std::string control;
    napi_get_cb_info(env,info,&argc,args,nullptr,nullptr);
    return amcl::napi::MakeBoolResult(env,argc==3 && ReadTouchIdentity(env,args[0],&token) &&
        ReadBoundedUtf8String(env,args[1],23,control) && ReadTouchIdentity(env,args[2],&epoch) &&
        amcl::input::BindTouchGroupMouseOwner(token,control,epoch));
}

napi_value InvokeTouchGroupControl(napi_env env,napi_callback_info info) {
    size_t argc = 6; napi_value args[6]{}; uint64_t token = 0, epoch = 0, producer = 0, sequence = 0;
    std::string control; int32_t phase = -1;
    napi_get_cb_info(env,info,&argc,args,nullptr,nullptr);
    if (argc != 6 || !ReadTouchIdentity(env,args[0],&token) || !ReadBoundedUtf8String(env,args[1],23,control) ||
        !ReadTouchIdentity(env,args[2],&epoch) || !ReadTouchIdentity(env,args[3],&producer) ||
        !ReadTouchIdentity(env,args[4],&sequence) || !StrictInt(env,args[5],&phase) || !GroupProducerCurrent(producer)) return amcl::napi::MakeUndefined(env);
    try {
        return GroupCommandReceipt(env,amcl::input::InvokeTouchGroupControl(token,control,epoch,producer,sequence,phase));
    } catch (...) { return amcl::napi::MakeUndefined(env); }
}

napi_value RestoreTouchGroups(napi_env env,napi_callback_info info) {
    size_t argc = 3; napi_value args[3]{}; uint64_t token = 0, producer = 0, sequence = 0;
    napi_get_cb_info(env,info,&argc,args,nullptr,nullptr);
    if (argc != 3 || !ReadTouchIdentity(env,args[0],&token) || !ReadTouchIdentity(env,args[1],&producer) ||
        !ReadTouchIdentity(env,args[2],&sequence) || !GroupProducerCurrent(producer)) return amcl::napi::MakeUndefined(env);
    try {
        return GroupCommandReceipt(env,amcl::input::RestoreTouchGroups(token,producer,sequence));
    } catch (...) { return amcl::napi::MakeUndefined(env); }
}

/** 必要组态通知拥有独立注册，不受可选按钮高亮/触觉的开关影响；载荷只是一项唤醒。 */
struct GroupNotification {
    napi_threadsafe_function tsfn = nullptr;
    uint64_t identity = 0;
    bool active = true, queued = false;
};
static std::mutex g_groupNotificationMutex;
static GroupNotification* g_groupNotification = nullptr;
static uint64_t g_groupNotificationIdentity = 1;
/** 当前必要通知注册也是前端命令生产者身份；旧页面的序号不能借相同布局 token 复活。 */
static bool GroupProducerCurrent(uint64_t identity) {
    std::lock_guard<std::mutex> lock(g_groupNotificationMutex);
    return g_groupNotification && g_groupNotification->active && g_groupNotification->identity == identity;
}
static void FinalizeGroupNotification(napi_env,void* data,void*) {
    auto* context = static_cast<GroupNotification*>(data);
    std::lock_guard<std::mutex> lock(g_groupNotificationMutex);
    if (g_groupNotification == context) g_groupNotification = nullptr;
    delete context;
}
static void GroupNotificationCallJs(napi_env env,napi_value callback,void* data,void*) {
    auto* context = static_cast<GroupNotification*>(data);
    {
        std::lock_guard<std::mutex> lock(g_groupNotificationMutex);
        if (!context || !context->active || g_groupNotification != context) return;
        context->queued = false;
    }
    napi_value receiver = nullptr, result = nullptr;
    if (env && callback && napi_get_undefined(env,&receiver) == napi_ok) napi_call_function(env,receiver,callback,0,nullptr,&result);
}
napi_value OnTouchGroupsChanged(napi_env env,napi_callback_info info) {
    size_t argc = 2; napi_value args[2]{}; napi_valuetype type = napi_undefined; uint64_t expected = 0;
    napi_get_cb_info(env,info,&argc,args,nullptr,nullptr);
    const bool attach = argc >= 1 && napi_typeof(env,args[0],&type) == napi_ok && type == napi_function;
    if (!attach && (argc != 2 || !ReadTouchIdentity(env,args[1],&expected))) return amcl::napi::WrapStringResult(env,"");
    GroupNotification* old = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_groupNotificationMutex);
        if (!attach && (!g_groupNotification || g_groupNotification->identity != expected)) return amcl::napi::WrapStringResult(env,"");
        old = g_groupNotification; g_groupNotification = nullptr;
        if (old) old->active = false;
    }
    if (old) napi_release_threadsafe_function(old->tsfn,napi_tsfn_release);
    if (!attach) return amcl::napi::WrapStringResult(env,"released");
    auto* context = new (std::nothrow) GroupNotification();
    if (!context) return amcl::napi::WrapStringResult(env,"");
    {
        std::lock_guard<std::mutex> lock(g_groupNotificationMutex);
        if (g_groupNotificationIdentity == UINT64_MAX) { delete context; return amcl::napi::WrapStringResult(env,""); }
        context->identity = ++g_groupNotificationIdentity;
    }
    napi_value name = nullptr;
    if (napi_create_string_utf8(env,"TouchGroups",NAPI_AUTO_LENGTH,&name) != napi_ok ||
        napi_create_threadsafe_function(env,args[0],nullptr,name,1,1,context,FinalizeGroupNotification,context,
            GroupNotificationCallJs,&context->tsfn) != napi_ok) { delete context; return amcl::napi::WrapStringResult(env,""); }
    { std::lock_guard<std::mutex> lock(g_groupNotificationMutex); g_groupNotification = context; }
    return amcl::napi::WrapStringResult(env,std::to_string(context->identity).c_str());
}
