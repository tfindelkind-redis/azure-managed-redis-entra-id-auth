#!/usr/bin/env python3
"""
Calculate Redis cluster slots for test keys.
This script helps find keys that will hit different shards.
"""

def crc16(data):
    """CRC16 implementation used by Redis Cluster."""
    crc = 0
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            if crc & 0x8000:
                crc = (crc << 1) ^ 0x1021
            else:
                crc <<= 1
            crc &= 0xFFFF
    return crc


def key_slot(key):
    """Calculate Redis cluster slot for a key."""
    # Handle hash tags {tag}
    start = key.find('{')
    if start >= 0:
        end = key.find('}', start + 1)
        if end > start + 1:
            key = key[start+1:end]
    return crc16(key.encode()) % 16384


def get_shard(slot, num_shards=2):
    """Determine which shard owns a slot."""
    slots_per_shard = 16384 // num_shards
    return slot // slots_per_shard


if __name__ == "__main__":
    print("Redis Cluster Slot Calculator")
    print("=" * 50)
    print()
    
    # Find hash tag values that land on different shards
    print("Finding hash tags for cross-shard testing (2 shards):")
    print()
    
    shard0_tags = []
    shard1_tags = []
    
    for i in range(1000):
        tag = f"slot{i}"
        slot = key_slot(tag)
        if slot < 8192 and len(shard0_tags) < 2:
            shard0_tags.append((tag, slot))
        elif slot >= 8192 and len(shard1_tags) < 2:
            shard1_tags.append((tag, slot))
        if len(shard0_tags) >= 2 and len(shard1_tags) >= 2:
            break
    
    print("Keys that will hit SHARD 0 (slots 0-8191):")
    for tag, slot in shard0_tags:
        print(f"  test:{{{{ {tag} }}}}:data  -> slot {slot}")
    
    print()
    print("Keys that will hit SHARD 1 (slots 8192-16383):")
    for tag, slot in shard1_tags:
        print(f"  test:{{{{ {tag} }}}}:data  -> slot {slot}")
    
    print()
    print("Recommended test keys with hash tags:")
    all_tags = shard0_tags + shard1_tags
    for tag, slot in all_tags:
        shard = "shard0" if slot < 8192 else "shard1"
        print(f'  "{{{tag}}}"  # slot {slot} -> {shard}')
