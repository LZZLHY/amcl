package com.amcl.compat.test;
import java.util.*;
import org.spongepowered.asm.service.*;
public final class TestProperties implements IGlobalPropertyService {
    private final Map<String, Object> values = new HashMap<>();
    private static final class Key implements IPropertyKey {
        final String name;
        Key(String name) { this.name = name; }
    }
    public IPropertyKey resolveKey(String name) { return new Key(name); }
    @SuppressWarnings("unchecked") public <T> T getProperty(IPropertyKey key) { return (T)values.get(((Key)key).name); }
    public void setProperty(IPropertyKey key, Object value) { values.put(((Key)key).name, value); }
    public <T> T getProperty(IPropertyKey key, T fallback) { T value = getProperty(key); return value == null ? fallback : value; }
    public String getPropertyString(IPropertyKey key, String fallback) { Object value = getProperty(key); return value == null ? fallback : value.toString(); }
}
