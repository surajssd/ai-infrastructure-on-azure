# Finetune & Inference with NeMo-Run

## Table of Contents

1. [Introduction](#1-introduction)
2. [Creating and Configuring Azure CycleCloud Workspaces for Slurm Environment](#2-creating-and-configuring-azure-cyclecloud-workspaces-for-slurm-environment)
3. [Finetune and Inference with NeMo-Run](#3-finetune-and-inference-with-nemo-run)

## 1. Introduction

In this example, we will demonstrate how to use NeMo-Run for distributed finetuning, using a Slurm cluster. We will also show how you can run a Slurm job for inferencing to test your model.

The references that have been used to build this example are:

- [NeMo](https://github.com/NVIDIA/NeMo) - a scalable, cloud-native generative AI framework designed to support the development of Large Language Models (LLMs) and Multimodal Models (MMs). The NeMo Framework provides comprehensive tools for efficient training, including Supervised Fine-Tuning (SFT) and Parameter Efficient Fine-Tuning (PEFT).
- [NeMo-Run](https://github.com/NVIDIA/NeMo-Run) - a tool within the NeMo framework to streamline the configuration, execution, and management of experiments across various computing environments.
- [NVIDIA NeMo Framework User Guide](https://docs.nvidia.com/nemo-framework/user-guide/latest/nemo-2.0/quickstart.html) - NVIDIA's documentation on the NeMo 2.0 framework, which includes examples that were used to build this guide.
- [Stanford Question Answering (SQuAD) Dataset](https://huggingface.co/datasets/rajpurkar/squad) - default dataset used by the recipe for finetuning in the example.
- [LLama 3-8B](https://huggingface.co/meta-llama/Meta-Llama-3-8B) - Llama 3 language model developed by Meta, which we will finetune in this example using the default recipe in the NeMo framework.
- [Azure CycleCloud Workspaces for Slurm](https://github.com/Azure/cyclecloud-slurm-workspace) - The Azure Marketplace offering which can be used to stand-up a Slurm cluster powered by Azure CycleCloud and Azure Storage, with pre-configured `enroot` and `pyxis` to support containerized workloads.
- [Open OnDemand](https://openondemand.org/) - an open-source web-based interface developed by the Ohio Supercomputer Center (OSC) that provides a user-friendly way to access and use high-performance computing (HPC) resources.

## 2. Creating and Configuring Azure CycleCloud Workspaces for Slurm Environment

The guide requires an Azure CycleCloud Workspace for Slurm (CCWS) environment. The NeMo-Run framework uses `sacct` to check the status of jobs, so the CCWS environment should be configured to use a pre-existing MySQL Flexible server for Slurm job accounting.

Additionally, this exercise is executed through a Jupyter notebook to highlight features from NeMo-Run like tailing logs in real time (or viewing logs after job completion), checking the status of an experiment, canceling it, within an interactive environment.

The notebook retains the information about the expermient, which allows end-users to revisit the notebook to review how the experiment was submitted, the results that were produced, and to re-run the experiment, if desired. Consequently, it is recommended to use the OnDemand integration within CCWS to run this example.

### Create a VNET

Create a **VNET** that includes the following subnets:

- A dedicated **mysql** subnet with the Microsoft.DBforMySQL/flexibleServers delegation as documented [here](https://learn.microsoft.com/en-us/azure/mysql/flexible-server/concepts-networking-vnet)
- A /29 **cyclecloud** subnet for the CycleCloud VM
- A **compute** subnet for the nodes, where the scheduler, login, ondemand, and compute nodes are created
- If desired, you can also include a subnet for Azure NetApp Files, Azure Managed Lustre, or Bastion

Keep in mind that CCWS does not allow connections via public IP, so if a Bastion is not deployed, you must peer the VNET to a hub that will allow you to connect privately to the VNET.

### Create an Azure Database for MySQL Flexible Server

Refer to this [quickstart](https://learn.microsoft.com/en-us/azure/mysql/flexible-server/quickstart-create-connect-server-vnet) to create an instance of MySQL Flexible Server with private access. Make sure to select **Private Access** in the **Networking** tab, and to select the VNET and subnet that you created earlier.

This can be done through infrastructure-as-code [following the infrastructure reference example](../../../infrastructure_references/azure_cyclecloud_workspaces_for_slurm/README.md#create-a-mysql-flexible-server).

Once the instance is created, adjust the server parameters as [needed](https://slurm.schedmd.com/accounting.html#:~:text=NOTE%3A%20Before%20running,than%20max_script_size.).

### Create an App Registration & Managed Identity

An **app registration** and a **managed identity** must be created to authenticate to the Open OnDemand portal via OIDC. The app registration should be configured to:

- Issue ID tokens:

![auth-id-tokens](images/grant-tokens.png)

- Use the managed identity as a credential:

![auth-federated-creds](images/fed-creds.png)

- Provide the upn as an optional claim:

![upn-token-setup](images/upn.png)

- Have access to view users' basic profile and to sign in and read user profiles:

![graph-api-setup](images/graph-perms.png)

### Deploy CCWS

You can use Azure CycleCloud Workspace for Slurm to deploy your cluster by following the [quickstart](https://learn.microsoft.com/en-us/azure/cyclecloud/qs-deploy-ccws?view=cyclecloud-8) steps.

As you customize your cluster, make sure to:

- Select the VNET you created in the **Networking** tab
- Check the box for **Slurm Job Accounting** and enter the details of your MySQL Flexible Server instance under the **Slurm Settings** tab
- Configure a GPU partition gpu with ND-series nodes. The example has been tested on Standard_ND96isr_H200_v5.
- Provide the client ID of your registered application, and the managed identity that you created in the **Open OnDemand** tab

Any sort of NFS home directory will be suitable for this example. There are no dependencies here for running this example. However, for running experiments at scale across a shared cluster, it is recommended to deploy an Azure Machine Learning Filesystem (AMLFS) or equivalent high-throughput shared storage.

### Create User Accounts

Once your cluster starts, make sure to create a local user account in CycleCloud that maps to the account that will be used to log in to the OnDemand portal. For example, if you are going to login with the account <aiuser@contoso.com>, create a user account with `aiuser` as the username and grant node access:

![user-create](images/user-create.png)

![user-perms](images/user-perms.png)

### Update your App registration

Update your app registration to use the OnDemand VM's IP address as the redirect URI:
![redirect-uri](images/redirect.png)

## 3. Finetune and Inference with NeMo-Run

### Install required packages

Use Open OnDemand to log in to your cluster through your browser:

```bash
https://< PRIVATE IP OR FQDN OF ONDEMAND >
```

Once you authenticate, OnDemand will redirect you to the landing page. Select **Clusters** > **Slurm ccw Shell Access**, to access an interactive shell against the login node of your cluster.

![shell-ood](images/ood-shell.png)

From the shell, clone this project from github:

```bash
git clone https://github.com/Azure/ai-infrastructure-on-azure.git
```

Run the setup script. The script will install uv and leverage it to create a python virtual environment and install the required packages to use NeMo-Run:

```bash
 ./ai-infrastructure-on-azure/examples/nemo-run/slurm/setup.sh
```

Once the script completes, you should see a folder in your home directory named `ccws-nemo-venv`.

### Run Example

Go back to the main page of OnDemand and select the **VSCode on Login Node** application.

![ood-vscode](images/ood-vscode.png)

You will be redirected to a page where you can input how long you want to run your VSCode session and provide the path of your working directory. If you installed the project in your home directory, you can proceed with the defaults by clicking on **Launch**:

![vscode-launch](images/vscode-launch.png)

After requesting the session, you will land on a page that lists your active interactive sessions. From that page, select **Connect to VS Code** for the session that you just created:

![vscode-connect](images/vscode-connect.png)

From VSCode, open the terminal and source the virtual environment that was previously created:

```bash
source ~/ccws-nemo-venv/bin/activate
```

Open the `.env-sample` file and populate the file with the required parameters:

```bash
GPUS_PER_NODE=8
NUM_NODES=2
GPU_PARTITION="gpu"
WALLTIME="1:00:00"
CONTAINER="nvcr.io#nvidia/nemo:dev"
NEMO_HOME="path-to-your-nemo-home"
CHECKPOINT_DIR="path-to-your-checkpoint-dir"
HF_TOKEN_PATH="path-to-your-huggingface-token"
HF_HOME="path-for-your-huggingface-cache"
MODEL_NAME="llama3_ft_ccws"
```

You can modify the `GPUS_PER_NODE` and `NUM_NODES` parameter to change the number of nodes and GPUs to use for the finetuning example. The following paths are required to run the project:

- `NEMO_HOME` - A directory to store the models and datasets that are converted by the framework to the NeMo format
- `CHECKPOINT_DIR` - A directory to store the model checkpoints
- `HF_TOKEN_PATH` - A path to a file that has a huggingface token with permissions to download datasets and models
- `HF_HOME` - A directory for your huggingface cache

> [!NOTE]
> These paths need to be on shared storage, as they will be mounted within the container when the job runs.

Rename the file to .env. You can do this from the terminal via the following command:

```bash
mv .env-sample .env
```

From VSCode, open the `ccws_nemo_finetune.ipynb` notebook. VSCode will recommend the installation of the Python and Jupyter extensions. Proceed with installation of both extensions.

Once the extensions are installed, you can select your kernel:

![select-kernel](images/select-kernel.png)

![jupyter-kernel](images/jupyter-kernel.png)

VSCode should detect your virtual environment, which will allow you to select it as the desired kernel for the notebook:

![python-venv](images/python-venv.png)

Once the kernel is selected, you can execute the cells, to run the finetune & inference examples.

By integrating NeMo-Run within a Jupyter Notebook, you gain the ability to seamlessly track, revisit, and re-submit experiments—enabling a reproducible and iterative research workflow with minimal overhead.
