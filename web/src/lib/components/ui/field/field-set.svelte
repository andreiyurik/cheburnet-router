<script>
	import { cn } from "$lib/utils.js";

	let {
		ref = $bindable(null),
		class: className,
		children,
		...restProps
	} = $props();
</script>

<fieldset
	bind:this={ref}
	data-slot="field-set"
	class={cn(
		"flex flex-col gap-6",
		"has-[>[data-slot=checkbox-group]]:gap-3 has-[>[data-slot=radio-group]]:gap-3",
		className
	)}
	{...restProps}
>
	{@render children?.()}
</fieldset>
