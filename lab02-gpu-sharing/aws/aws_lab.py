"""Lab 2, optional GPU part: share one real GPU between pods (time-slicing, then MPS) on AWS.

    python aws/aws_lab.py quota      # your GPU quota (needs 4 vCPUs of "G and VT" instances)
    python aws/aws_lab.py up         # launch one GPU instance; it runs the whole experiment itself
    python aws/aws_lab.py results    # print what the instance measured, and save it under runs/
    python aws/aws_lab.py status     # is anything still running, and for how long
    python aws/aws_lab.py down       # delete everything `up` created

Cost rules built in:
  * the instance terminates itself MAX_MINUTES after boot, even if you forget `down`;
  * `down` deletes the whole stack and waits until AWS confirms it is gone;
  * no inbound ports, no SSH key: results come back through the instance console.
Check current GPU prices on the AWS pricing page before you run `up`.
"""
import argparse
import datetime as dt
import pathlib
import sys
import time

import boto3
from botocore.exceptions import ClientError

REGIONS = ["us-east-1", "us-east-2", "us-west-2"]   # `up` tries these in order
REGION = REGIONS[0]
STACK = "kubernetes-labs-lab02"
TAG = "kubernetes-labs"
# All have 4 vCPUs and one NVIDIA GPU (L40S, L4, A10G): the same "G and VT" quota.
INSTANCE_TYPES = ["g6.xlarge", "g5.xlarge", "g6e.xlarge"]   # g6.xlarge (1x L4) first: the type our runs used
INSTANCE_VCPUS = 4
MAX_MINUTES = 55
QUOTA_CODE = "L-DB2E81BA"     # EC2 "Running On-Demand G and VT instances" (vCPUs)
DLAMI_SSM = ("/aws/service/deeplearning/ami/x86_64/"
             "base-oss-nvidia-driver-gpu-ubuntu-22.04/latest/ami-id")
HERE = pathlib.Path(__file__).parent
TEMPLATE = HERE / "gpu-sharing.yaml"
RUNS = HERE.parent / "runs"


def client(name):
    return boto3.client(name, region_name=REGION)


def use_region(name):
    global REGION
    REGION = name


def stack_exists():
    try:
        client("cloudformation").describe_stacks(StackName=STACK)
        return True
    except ClientError:
        return False


def find_stack_region():
    for r in REGIONS:
        use_region(r)
        if stack_exists():
            return r
    use_region(REGIONS[0])
    return None


def stack_instance():
    try:
        outs = client("cloudformation").describe_stacks(StackName=STACK)["Stacks"][0].get("Outputs", [])
    except ClientError:
        return None
    return next((o["OutputValue"] for o in outs if o["OutputKey"] == "InstanceId"), None)


def gpu_quota():
    return client("service-quotas").get_service_quota(ServiceCode="ec2", QuotaCode=QUOTA_CODE)["Quota"]["Value"]


def lab_lines(instance_id):
    """The LAB02| lines the instance printed to its console, in order."""
    out = client("ec2").get_console_output(InstanceId=instance_id, Latest=True).get("Output", "")
    return [line.split("LAB02| ", 1)[1].rstrip() for line in out.splitlines() if "LAB02| " in line]


def subnets_for(itype):
    ec2 = client("ec2")
    offered = {o["Location"] for o in ec2.describe_instance_type_offerings(
        LocationType="availability-zone",
        Filters=[{"Name": "instance-type", "Values": [itype]}])["InstanceTypeOfferings"]}
    subs = ec2.describe_subnets(Filters=[{"Name": "default-for-az", "Values": ["true"]}])["Subnets"]
    return sorted((s["AvailabilityZone"], s["SubnetId"]) for s in subs if s["AvailabilityZone"] in offered)


def try_create(itype):
    """Create the stack with this instance type, zone by zone. Returns True when an instance is running."""
    ami = client("ssm").get_parameter(Name=DLAMI_SSM)["Parameter"]["Value"]
    image = client("ec2").describe_images(ImageIds=[ami])["Images"][0]
    cf = client("cloudformation")
    params = [{"ParameterKey": "ImageId", "ParameterValue": ami},
              {"ParameterKey": "InstanceType", "ParameterValue": itype},
              {"ParameterKey": "MaxMinutes", "ParameterValue": str(MAX_MINUTES)},
              {"ParameterKey": "RootDeviceName", "ParameterValue": image["RootDeviceName"]}]
    for az, subnet in subnets_for(itype):
        print(f"{REGION} {az}: creating {itype} from {image['Name']} ... "
              f"(terminates itself by {dt.datetime.now() + dt.timedelta(minutes=MAX_MINUTES):%H:%M} at the latest)")
        cf.create_stack(StackName=STACK, TemplateBody=TEMPLATE.read_text(),
                        Parameters=params + [{"ParameterKey": "SubnetId", "ParameterValue": subnet}],
                        Tags=[{"Key": "Project", "Value": TAG}])
        try:
            cf.get_waiter("stack_create_complete").wait(StackName=STACK)
            return True
        except Exception:
            ev = cf.describe_stack_events(StackName=STACK)["StackEvents"]
            why = next((e.get("ResourceStatusReason", "") for e in reversed(ev)
                        if e["ResourceStatus"] == "CREATE_FAILED"), "unknown")
            print(f"   failed: {why[:200]}")
            cf.delete_stack(StackName=STACK)
            cf.get_waiter("stack_delete_complete").wait(StackName=STACK)
            if "capacity" not in why.lower():
                raise SystemExit("Stopped. Nothing is left running.")
    return False


def cmd_quota(args):
    for r in REGIONS:
        use_region(r)
        print(f"{r}: G and VT On-Demand quota {gpu_quota():g} vCPUs (this lab needs {INSTANCE_VCPUS})")
    return 0


def cmd_up(args):
    if find_stack_region():
        print(f"Stack {STACK} already exists in {REGION}. Run `python aws/aws_lab.py down` first.")
        return 1
    started = False
    for r in REGIONS:
        use_region(r)
        if gpu_quota() < INSTANCE_VCPUS:
            print(f"{r}: GPU quota below {INSTANCE_VCPUS} vCPUs; skipping.")
            continue
        for itype in ([args.instance_type] if args.instance_type else INSTANCE_TYPES):
            if try_create(itype):
                started = True
                break
        if started:
            break
    if not started:
        print("No GPU capacity (or quota) right now in " + ", ".join(REGIONS) + ". Nothing is left running.")
        return 1
    iid = stack_instance()
    global RUN_INFO
    RUN_INFO = f"region={REGION} instance_type={itype}"
    print(f"Instance {iid} ({itype}, {REGION}) is running. It installs Kubernetes and runs the experiment by itself (about 20-30 min).")
    print("Progress (console output can lag a few minutes):")
    seen = 0
    for _ in range(100):                      # up to ~50 minutes
        lines = lab_lines(iid)
        for line in lines[seen:]:
            print("  " + line)
        seen = max(seen, len(lines))
        if any(line.startswith("DONE") for line in lines):
            break
        time.sleep(30)
    save(lines)
    print("Next: python aws/aws_lab.py down")
    return 0


RUN_INFO = ""


def save(lines):
    RUNS.mkdir(exist_ok=True)
    if RUN_INFO:
        lines = [RUN_INFO] + lines
    p = RUNS / f"aws-{dt.datetime.now():%Y%m%d-%H%M%S}.log"
    p.write_text("\n".join(lines) + "\n")
    print(f"Saved {len(lines)} lines to {p}")


def cmd_results(args):
    global RUN_INFO
    find_stack_region()
    iid = stack_instance()
    if iid:
        inst = client("ec2").describe_instances(InstanceIds=[iid])["Reservations"][0]["Instances"][0]
        RUN_INFO = f"region={REGION} instance_type={inst['InstanceType']}"
    if not iid:
        print("No lab instance found.")
        return 1
    lines = lab_lines(iid)
    print("\n".join(lines))
    save(lines)
    return 0


def cmd_status(args):
    find_stack_region()
    iid = stack_instance()
    if not iid:
        print(f"No stack named {STACK}: nothing from this lab is running.")
        return 0
    inst = client("ec2").describe_instances(InstanceIds=[iid])["Reservations"][0]["Instances"][0]
    print(f"{REGION}: instance {iid} ({inst['InstanceType']}) is {inst['State']['Name']}.")
    if inst["State"]["Name"] == "running":
        left = MAX_MINUTES - (dt.datetime.now(dt.timezone.utc) - inst["LaunchTime"]).total_seconds() / 60
        print(f"It terminates itself in about {max(left, 0):.0f} minutes.")
    print("Delete everything with: python aws/aws_lab.py down")
    return 0


def cmd_down(args):
    if not find_stack_region():
        print("Nothing to delete.")
        return 0
    cf = client("cloudformation")
    cf.delete_stack(StackName=STACK)
    print(f"Deleting stack {STACK} in {REGION} (instance, disk, launch template, security group)...")
    cf.get_waiter("stack_delete_complete").wait(StackName=STACK)
    left = client("ec2").describe_instances(Filters=[
        {"Name": "tag:Project", "Values": [TAG]},
        {"Name": "instance-state-name", "Values": ["pending", "running", "stopping", "stopped"]}])
    if any(r["Instances"] for r in left["Reservations"]):
        print("WARNING: a kubernetes-labs instance still exists. Check the EC2 console.")
        return 1
    print("Deleted. Nothing from this lab is left in", REGION)
    return 0


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sp = p.add_subparsers(dest="cmd", required=True)
    for name in ("quota", "results", "status", "down"):
        sp.add_parser(name)
    u = sp.add_parser("up")
    u.add_argument("--instance-type", choices=INSTANCE_TYPES,
                   help="only this type (default: try " + ", ".join(INSTANCE_TYPES) + " in that order)")
    args = p.parse_args()
    return {"quota": cmd_quota, "up": cmd_up, "results": cmd_results,
            "status": cmd_status, "down": cmd_down}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
